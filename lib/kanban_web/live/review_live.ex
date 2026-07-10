defmodule KanbanWeb.ReviewLive do
  @moduledoc """
  Workspace-level Review Queue at `/review`.

  Composes `KanbanWeb.ReviewQueueItem`, `KanbanWeb.ReviewDetailHeader`,
  `KanbanWeb.ReviewStatsStrip`, `KanbanWeb.ReviewDiffPanel`, and the
  existing `KanbanWeb.AcceptanceChecklist` into a two-pane page where
  the reviewer scans the queue on the left and inspects the selected
  task on the right.

  All read data flows through `Kanban.Reviews.list_pending_reviews/1` and
  `Kanban.Reviews.queue_stats/1`; the approve and request-changes
  mutations route through `Kanban.Reviews.approve_review/3` and
  `Kanban.Reviews.request_changes_review/3`. No Ecto queries live in
  this module — the LiveView is a thin binding layer between the context
  and the presentational components.
  """
  use KanbanWeb, :live_view

  alias Kanban.Reviews
  alias Kanban.Tasks.ChangedFilesAudit
  alias Kanban.Tasks.Task
  alias KanbanWeb.AcceptanceChecklist
  alias KanbanWeb.CodeReviewPanel
  alias KanbanWeb.ReviewAcceptance
  alias KanbanWeb.ReviewDetailHeader
  alias KanbanWeb.ReviewDiffPanel
  alias KanbanWeb.ReviewQueueItem
  alias KanbanWeb.ReviewReportHelpers
  alias KanbanWeb.ReviewReportPanel
  alias KanbanWeb.ReviewStatsStrip

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load_queue(socket)}
  end

  @impl true
  def handle_event("select_item", %{"id" => id}, socket) do
    task = find_pending_by_id(socket.assigns.pending, id)

    {:noreply,
     socket
     |> emit_panel_closed_if_open()
     |> assign(:selected, task)
     |> assign(:request_changes_open?, false)
     |> assign(:selected_changed_file, nil)}
  end

  @impl true
  def handle_event("deselect_item", _params, socket) do
    {:noreply,
     socket
     |> emit_panel_closed_if_open()
     |> assign(:selected, nil)
     |> assign(:request_changes_open?, false)
     |> assign(:selected_changed_file, nil)}
  end

  @impl true
  def handle_event("select_changed_file", %{"path" => path}, socket) when is_binary(path) do
    if socket.assigns[:selected_changed_file] == path do
      # Toggle off — clicking the already-open file collapses the diff view.
      {:noreply,
       socket
       |> emit_panel_closed_if_open()
       |> assign(:selected_changed_file, nil)}
    else
      {:noreply,
       socket
       |> emit_panel_opened_if_first(path)
       |> assign(:selected_changed_file, path)}
    end
  end

  @impl true
  def handle_event("approve", _params, socket) do
    case socket.assigns.selected do
      nil ->
        {:noreply, socket}

      %{} = task ->
        socket.assigns.current_scope
        |> Reviews.approve_review(task)
        |> case do
          {:ok, _approved} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Approved %{ident}", ident: task.identifier))
             |> remove_from_queue(task)}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Unable to approve task."))}
        end
    end
  end

  @impl true
  def handle_event("request_changes", _params, socket) do
    {:noreply, assign(socket, :request_changes_open?, true)}
  end

  @impl true
  def handle_event("cancel_request_changes", _params, socket) do
    {:noreply, assign(socket, :request_changes_open?, false)}
  end

  @impl true
  def handle_event("submit_request_changes", params, socket) do
    do_submit_request_changes(socket, socket.assigns.selected, extract_notes(params))
  end

  @impl true
  def handle_event("refetch_diff", _params, socket) do
    do_refetch_diff(socket, socket.assigns.selected)
  end

  # --- Request-changes helpers ---------------------------------------------

  defp do_submit_request_changes(socket, nil, _notes), do: {:noreply, socket}

  defp do_submit_request_changes(socket, _task, notes) do
    if blank?(notes) do
      {:noreply, notes_required_flash(socket)}
    else
      apply_request_changes(socket, socket.assigns.selected, notes)
    end
  end

  defp apply_request_changes(socket, task, notes) do
    socket.assigns.current_scope
    |> Reviews.request_changes_review(task, review_notes: notes)
    |> case do
      {:ok, _updated} -> {:noreply, request_changes_success(socket, task)}
      {:error, :review_notes_required} -> {:noreply, notes_required_flash(socket)}
      {:error, _reason} -> {:noreply, request_changes_failure_flash(socket)}
    end
  end

  defp request_changes_success(socket, task) do
    # Request-changes leaves the task in the Review column (the agent will
    # move it back to Doing once they address the notes), but the row
    # drops out of the reviewer's queue — the human's job on this task is
    # done.
    socket
    |> put_flash(:info, gettext("Requested changes on %{ident}", ident: task.identifier))
    |> remove_from_queue(task)
  end

  defp notes_required_flash(socket) do
    put_flash(socket, :error, gettext("Notes are required when requesting changes."))
  end

  defp request_changes_failure_flash(socket) do
    put_flash(socket, :error, gettext("Unable to request changes on task."))
  end

  # --- Diff re-fetch --------------------------------------------------------
  #
  # When a review task arrived with its diff lost in transit — it changed
  # files but `changed_files` is empty, see
  # `Kanban.Tasks.ChangedFilesAudit.diff_missing?/1` — the reviewer can ask
  # the LiveView to reload the task from the database in case the diff has
  # since been (re-)uploaded. The reload routes through the same scoped
  # `Reviews.get_pending_review/2` used elsewhere, so it enforces the caller's
  # board authorization: a reviewer can only re-fetch a task on a board they
  # can access, and the returned task is exactly what the queue already shows.

  defp do_refetch_diff(socket, nil), do: {:noreply, socket}

  defp do_refetch_diff(socket, %{id: id}) do
    case Reviews.get_pending_review(socket.assigns.current_scope, id) do
      {:ok, reloaded} ->
        {:noreply, apply_refetched_task(socket, reloaded)}

      {:error, :not_found} ->
        {:noreply,
         put_flash(socket, :error, gettext("This task is no longer available for review."))}
    end
  end

  defp apply_refetched_task(socket, reloaded) do
    new_pending =
      Enum.map(socket.assigns.pending, fn task ->
        if task.id == reloaded.id, do: reloaded, else: task
      end)

    socket
    |> assign(:pending, new_pending)
    |> assign(:selected, reloaded)
    |> refetch_result_flash(reloaded)
  end

  defp refetch_result_flash(socket, task) do
    if diff_missing?(task) do
      put_flash(
        socket,
        :info,
        gettext(
          "The diff has not been re-uploaded yet — re-run the task's completion to send it."
        )
      )
    else
      put_flash(socket, :info, gettext("Diff reloaded."))
    end
  end

  # --- Diff panel telemetry -------------------------------------------------
  #
  # Two events, scoped to needs_review=true tasks only:
  #
  #   * `[:kanban, :review_diff_panel, :opened]` — fires once per task review
  #     session, the first time a reviewer selects a file in the diff panel.
  #     Re-selecting the same file or selecting a different file within the
  #     same task does not re-emit (the open/close pair is the session-level
  #     signal, not the per-file click).
  #   * `[:kanban, :review_diff_panel, :closed]` — fires when the open session
  #     ends: task switch, task deselect, or LiveView teardown (`terminate/2`).
  #
  # Measurements: `system_time` (monotonic-friendly System.system_time/0).
  # Metadata: `task_id`. Downstream subscribers compute open-rate (count of
  # :opened) and time-spent (matched :closed timestamp minus :opened).
  #
  # `diff_panel_opened_for_task_id` on the socket assigns is the open-session
  # marker — set to the task id when :opened fires, cleared when :closed
  # fires. A panel-opened for a task whose `needs_review` is false is never
  # emitted (the requirements metric is scoped to review-gated work).

  @impl true
  def terminate(_reason, socket) do
    emit_panel_closed_if_open(socket)
    :ok
  end

  defp emit_panel_opened_if_first(socket, _path) do
    case socket.assigns.selected do
      %{id: task_id, needs_review: true} ->
        if socket.assigns.diff_panel_opened_for_task_id == task_id do
          socket
        else
          :telemetry.execute(
            [:kanban, :review_diff_panel, :opened],
            %{system_time: System.system_time(), count: 1},
            %{task_id: task_id}
          )

          assign(socket, :diff_panel_opened_for_task_id, task_id)
        end

      _ ->
        socket
    end
  end

  defp emit_panel_closed_if_open(socket) do
    case socket.assigns[:diff_panel_opened_for_task_id] do
      nil ->
        socket

      task_id ->
        :telemetry.execute(
          [:kanban, :review_diff_panel, :closed],
          %{system_time: System.system_time(), count: 1},
          %{task_id: task_id}
        )

        assign(socket, :diff_panel_opened_for_task_id, nil)
    end
  end

  # --- Data loading ---------------------------------------------------------

  defp load_queue(socket) do
    scope = socket.assigns.current_scope
    pending = Reviews.list_pending_reviews(scope: scope)
    stats = Reviews.queue_stats(scope: scope)

    socket
    |> assign(:pending, pending)
    |> assign(:stats, stats)
    |> assign(:selected, List.first(pending))
    |> assign(:request_changes_open?, false)
    |> assign(:selected_changed_file, nil)
    |> assign(:diff_panel_opened_for_task_id, nil)
  end

  defp remove_from_queue(socket, %{id: id}) do
    scope = socket.assigns.current_scope
    new_pending = Enum.reject(socket.assigns.pending, &(&1.id == id))
    new_stats = Reviews.queue_stats(scope: scope)
    new_selected = next_selection(socket.assigns.selected, new_pending, id)

    socket
    |> emit_panel_closed_if_open()
    |> assign(:pending, new_pending)
    |> assign(:stats, new_stats)
    |> assign(:selected, new_selected)
    |> assign(:request_changes_open?, false)
    |> assign(:selected_changed_file, nil)
  end

  defp next_selection(%{id: selected_id}, new_pending, removed_id)
       when selected_id == removed_id,
       do: List.first(new_pending)

  defp next_selection(selected, _new_pending, _removed_id), do: selected

  defp find_pending_by_id(pending, id) when is_list(pending) do
    Enum.find(pending, fn task -> to_string(task.id) == to_string(id) end)
  end

  # Used in review_live.html.heex (analyzer does not scan HEEx files).
  defp selected?(nil, _item), do: false
  defp selected?(%{id: a}, %{id: b}), do: a == b

  # --- Derived display values ----------------------------------------------

  # Used in review_live.html.heex (analyzer does not scan HEEx files).
  defp queue_subtitle(%{count: 0}) do
    gettext("0 tasks waiting on you.")
  end

  defp queue_subtitle(%{count: count, distinct_agents: agents, oldest_age_minutes: oldest}) do
    head =
      ngettext(
        "%{count} task from %{agents} agent waiting on you",
        "%{count} tasks from %{agents} agents waiting on you",
        count,
        count: count,
        agents: agents
      )

    case oldest_age_label(oldest) do
      nil -> head
      age -> "#{head} · #{gettext("oldest %{age}", age: age)}"
    end
  end

  defp oldest_age_label(nil), do: nil
  defp oldest_age_label(0), do: gettext("just now")
  defp oldest_age_label(minutes) when minutes < 60, do: gettext("%{m}m ago", m: minutes)

  defp oldest_age_label(minutes) when minutes < 1440,
    do: gettext("%{h}h ago", h: div(minutes, 60))

  defp oldest_age_label(minutes), do: gettext("%{d}d ago", d: div(minutes, 1440))

  # Used in review_live.html.heex (analyzer does not scan HEEx files).
  defp summary_text(%{what: what}) when is_binary(what) and what != "", do: what
  defp summary_text(%{description: desc}) when is_binary(desc) and desc != "", do: desc
  defp summary_text(_), do: ""

  # Used in review_live.html.heex (analyzer does not scan HEEx files).
  defp present_text?(s) when is_binary(s), do: String.trim(s) != ""
  defp present_text?(_), do: false

  # Whether the selected task's diff is missing — it changed files but no
  # `changed_files` diff arrived (the upload was lost in transit). Drives the
  # explicit "Diff not uploaded" banner that renders in place of the diff
  # panel. Delegates to the shared `ChangedFilesAudit.diff_missing?/1`
  # predicate (D128) so the UI and the server-side audit agree exactly on
  # what "missing" means.
  # Used in review_live.html.heex (analyzer does not scan HEEx files).
  defp diff_missing?(%Task{} = task), do: ChangedFilesAudit.diff_missing?(task)
  defp diff_missing?(_), do: false

  # Builds the per-file payload passed to the diff panel. Looks up the
  # selected path in the task's persisted `changed_files` jsonb (see
  # `docs/diff-contract.md` for the shape). Falls back to a path-only
  # entry with `diff: nil` for legacy completion payloads that did not
  # carry per-file diff data — the panel renders "no diff available" in
  # that case.
  # Used in review_live.html.heex (analyzer does not scan HEEx files).
  defp selected_file_payload(_task, nil), do: nil

  defp selected_file_payload(task, path) when is_binary(path) do
    entry = lookup_changed_file(task, path) || %{}
    Map.merge(%{"path" => path, "diff" => nil}, entry)
  end

  defp lookup_changed_file(%{changed_files: list}, path) when is_list(list) do
    Enum.find(list, fn entry -> is_map(entry) and entry["path"] == path end)
  end

  defp lookup_changed_file(_task, _path), do: nil

  # Source of truth for the diff-panel file list. Unions the schema-1.0
  # `changed_files` jsonb array (`[%{"path", "diff", "diff_url"}]`) with
  # the legacy comma-separated `actual_files_changed` string — paths from
  # `changed_files` come first (they have rich diff data), legacy-only
  # paths are appended afterwards so the panel still lists them even
  # when the new plugin omitted them from the structured payload.
  # Used in review_live.html.heex (analyzer does not scan HEEx files).
  defp task_files(task) do
    structured_paths = changed_file_paths(task)
    legacy_paths = parse_files(Map.get(task, :actual_files_changed))

    structured_paths ++ Enum.reject(legacy_paths, &(&1 in structured_paths))
  end

  defp changed_file_paths(%{changed_files: list}) when is_list(list),
    do: Enum.flat_map(list, &changed_file_path/1)

  defp changed_file_paths(_), do: []

  defp changed_file_path(%{"path" => path}) when is_binary(path) and path != "", do: [path]
  defp changed_file_path(%{path: path}) when is_binary(path) and path != "", do: [path]
  defp changed_file_path(_), do: []

  defp parse_files(nil), do: []
  defp parse_files(""), do: []

  defp parse_files(text) when is_binary(text) do
    text
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_files(_), do: []

  # --- Param helpers --------------------------------------------------------

  defp extract_notes(%{"review" => %{"notes" => notes}}) when is_binary(notes), do: notes
  defp extract_notes(_), do: ""

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: true
end
