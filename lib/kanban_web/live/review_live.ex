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
  alias KanbanWeb.AcceptanceChecklist
  alias KanbanWeb.ReviewDetailHeader
  alias KanbanWeb.ReviewDiffPanel
  alias KanbanWeb.ReviewQueueItem
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
     |> assign(:selected, task)
     |> assign(:request_changes_open?, false)}
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
  def handle_event("view_diff", _params, socket) do
    # Real diff viewing is deferred (no diff data exists on Task) — see
    # the W569 out_of_scope list. Acknowledge the click with no state
    # change so the button is wired for future expansion.
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:review}>
      <:breadcrumbs>
        <span>{gettext("Workspace")}</span>
        <span style="color: var(--ink-4);">/</span>
        <span style="color: var(--ink); font-weight: 500;">{gettext("Review queue")}</span>
      </:breadcrumbs>

      <div
        class="stride-screen"
        style="display: flex; flex-direction: column; height: 100%; min-height: 0;"
      >
        <header
          data-review-header
          style={[
            "display: flex; align-items: flex-start; gap: 16px;",
            "padding: 16px 24px;",
            "border-bottom: 1px solid var(--line);",
            "background: var(--surface);"
          ]}
        >
          <div style="display: flex; flex-direction: column; gap: 4px;">
            <h1 style={[
              "margin: 0; font-size: 18px; font-weight: 600;",
              "letter-spacing: -0.01em; color: var(--ink);"
            ]}>
              {gettext("Review queue")}
            </h1>
            <p
              data-review-header-subtitle
              style="margin: 0; font-size: 12.5px; color: var(--ink-3);"
            >
              {queue_subtitle(@stats)}
            </p>
          </div>
          <span style="flex: 1;" />
          <span
            data-review-header-avg-time
            style={[
              "font-size: 11px; font-family: var(--font-mono);",
              "color: var(--ink-3); white-space: nowrap;"
            ]}
          >
            {gettext("Avg time to review · 17m")}
          </span>
        </header>

        <div style="display: flex; flex: 1; min-height: 0;">
          <aside
            data-review-queue-rail
            style={[
              "width: 380px; flex-shrink: 0;",
              "overflow-y: auto;",
              "border-right: 1px solid var(--line);",
              "background: var(--surface-2);"
            ]}
          >
            <p
              :if={@pending == []}
              data-review-queue-empty
              style={[
                "margin: 0; padding: 24px 16px; text-align: center;",
                "font-size: 12.5px; font-style: italic;",
                "color: var(--ink-3);"
              ]}
            >
              {gettext("Inbox zero — nothing is waiting for review.")}
            </p>

            <ReviewQueueItem.review_queue_item
              :for={item <- @pending}
              item={item}
              selected={selected?(@selected, item)}
              on_click="select_item"
            />
          </aside>

          <section
            data-review-detail
            style={[
              "flex: 1; min-width: 0; overflow-y: auto;",
              "display: flex; flex-direction: column;"
            ]}
          >
            <div
              :if={@selected == nil}
              data-review-detail-empty
              style={[
                "padding: 48px 24px; text-align: center;",
                "font-size: 13px; color: var(--ink-3); font-style: italic;"
              ]}
            >
              {gettext("Select a task from the queue to start a review.")}
            </div>

            <div :if={@selected != nil}>
              <ReviewDetailHeader.review_detail_header
                task={@selected}
                on_approve="approve"
                on_request_changes="request_changes"
                on_view_diff="view_diff"
              />

              <div
                data-review-detail-summary
                style={[
                  "padding: 14px 16px;",
                  "font-size: 13px; line-height: 1.55; color: var(--ink);"
                ]}
              >
                {summary_text(@selected)}
              </div>

              <ReviewStatsStrip.review_stats_strip
                acceptance={acceptance_value(@selected)}
                diff={diff_value(@selected)}
              />

              <ReviewDiffPanel.review_diff_panel files={parse_files(@selected.actual_files_changed)} />

              <div style="padding: 12px 16px;">
                <AcceptanceChecklist.acceptance_checklist acceptance_criteria={
                  @selected.acceptance_criteria
                } />
              </div>

              <form
                :if={@request_changes_open?}
                data-review-request-changes-form
                phx-submit="submit_request_changes"
                style={[
                  "padding: 14px 16px; border-top: 1px solid var(--line);",
                  "display: flex; flex-direction: column; gap: 10px;",
                  "background: var(--surface-sunken);"
                ]}
              >
                <label
                  for="review-notes"
                  style="font-size: 12px; font-weight: 600; color: var(--ink);"
                >
                  {gettext("Notes for the agent")}
                </label>
                <textarea
                  id="review-notes"
                  name="review[notes]"
                  rows="4"
                  required
                  style={[
                    "width: 100%; padding: 8px 10px;",
                    "font-family: var(--font-mono); font-size: 12px;",
                    "color: var(--ink); background: var(--surface);",
                    "border: 1px solid var(--line); border-radius: 6px;"
                  ]}
                ></textarea>
                <div style="display: flex; gap: 8px; justify-content: flex-end;">
                  <.button type="button" phx-click="cancel_request_changes">
                    {gettext("Cancel")}
                  </.button>
                  <.button variant="primary" type="submit">
                    {gettext("Send request")}
                  </.button>
                </div>
              </form>
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
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
  end

  defp remove_from_queue(socket, %{id: id}) do
    scope = socket.assigns.current_scope
    new_pending = Enum.reject(socket.assigns.pending, &(&1.id == id))
    new_stats = Reviews.queue_stats(scope: scope)
    new_selected = next_selection(socket.assigns.selected, new_pending, id)

    socket
    |> assign(:pending, new_pending)
    |> assign(:stats, new_stats)
    |> assign(:selected, new_selected)
    |> assign(:request_changes_open?, false)
  end

  defp next_selection(%{id: selected_id}, new_pending, removed_id)
       when selected_id == removed_id,
       do: List.first(new_pending)

  defp next_selection(selected, _new_pending, _removed_id), do: selected

  defp find_pending_by_id(pending, id) when is_list(pending) do
    Enum.find(pending, fn task -> to_string(task.id) == to_string(id) end)
  end

  defp selected?(nil, _item), do: false
  defp selected?(%{id: a}, %{id: b}), do: a == b

  # --- Derived display values ----------------------------------------------

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

  defp summary_text(%{what: what}) when is_binary(what) and what != "", do: what
  defp summary_text(%{description: desc}) when is_binary(desc) and desc != "", do: desc
  defp summary_text(_), do: ""

  defp acceptance_value(task) do
    # Checked-state for acceptance criteria is not yet persisted on Task,
    # so reporting "N/N" would falsely imply every line is verified.
    # Surface the line count alone until real progress is tracked.
    case parse_lines(task.acceptance_criteria) do
      [] -> nil
      lines -> lines |> length() |> Integer.to_string()
    end
  end

  defp diff_value(task) do
    case parse_files(task.actual_files_changed) do
      [] -> nil
      files -> ngettext("%{count} file", "%{count} files", length(files), count: length(files))
    end
  end

  defp parse_lines(nil), do: []

  defp parse_lines(text) when is_binary(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_lines(_), do: []

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
