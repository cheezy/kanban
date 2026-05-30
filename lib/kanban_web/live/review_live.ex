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
  alias KanbanWeb.CodeReviewPanel
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

        <div class="flex-1 min-h-0 flex flex-col md:flex-row">
          <aside
            data-review-queue-rail
            class={[
              "flex-1 md:flex-none w-full md:w-[380px] md:flex-shrink-0 overflow-y-auto",
              if(@selected, do: "hidden md:block", else: "block")
            ]}
            style={[
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
            class={[
              "flex-1 min-w-0 overflow-y-auto md:flex md:flex-col",
              if(@selected, do: "flex flex-col", else: "hidden md:flex")
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
              <button
                type="button"
                phx-click="deselect_item"
                class="md:hidden inline-flex items-center gap-2 min-h-11 px-4 py-2 text-sm font-medium text-base-content hover:opacity-70 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
                style="border-bottom: 1px solid var(--line);"
                aria-label={gettext("Back to review queue")}
              >
                <.icon name="hero-arrow-left" class="w-4 h-4" />
                {gettext("Back to queue")}
              </button>
              <ReviewDetailHeader.review_detail_header
                task={@selected}
                on_approve="approve"
                on_request_changes="request_changes"
              />

              <form
                :if={@request_changes_open?}
                id="review-request-changes-form"
                data-review-request-changes-form
                phx-submit="submit_request_changes"
                phx-mounted={Phoenix.LiveView.JS.focus(to: "#review-notes")}
                style={[
                  "padding: 14px 16px; border-bottom: 1px solid var(--line);",
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
                <div class="flex flex-wrap gap-2 justify-end">
                  <.button type="button" phx-click="cancel_request_changes">
                    {gettext("Cancel")}
                  </.button>
                  <.button variant="primary" type="submit">
                    {gettext("Send request")}
                  </.button>
                </div>
              </form>

              <div
                data-review-detail-summary
                style={[
                  "padding: 14px 16px;",
                  "color: var(--ink);",
                  "display: flex; align-items: flex-start; gap: 10px;"
                ]}
              >
                <span
                  :if={review_status_pill(@selected)}
                  data-review-detail-summary-status={review_status_pill(@selected).status}
                  style={[
                    "flex-shrink: 0;",
                    "display: inline-flex; align-items: center; gap: 6px;",
                    "padding: 4px 12px; border-radius: 999px;",
                    "font-size: 13px; font-weight: 600;",
                    "letter-spacing: 0.02em;",
                    "margin-top: 6px;",
                    review_status_pill(@selected).style
                  ]}
                >
                  <.icon name={review_status_pill(@selected).icon} class="w-4 h-4" />
                  {review_status_pill(@selected).label}
                </span>
                <div style="flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 4px;">
                  <h2
                    data-review-detail-summary-title
                    style={[
                      "margin: 0; font-size: 20px; font-weight: 600;",
                      "letter-spacing: -0.01em; line-height: 1.2; color: var(--ink);"
                    ]}
                  >
                    {@selected.title}
                  </h2>
                  <p
                    :if={present_text?(summary_text(@selected))}
                    data-review-detail-summary-description
                    style="margin: 0; font-size: 13px; line-height: 1.55; color: var(--ink-2);"
                  >
                    {summary_text(@selected)}
                  </p>
                </div>
              </div>

              <ReviewStatsStrip.review_stats_strip
                acceptance={acceptance_value(@selected)}
                acceptance_passed={acceptance_passed(@selected)}
                tests={ReviewReportHelpers.testing_strategy_value(@selected)}
                tests_passed={ReviewReportHelpers.testing_strategy_passed(@selected)}
                diff={ReviewReportHelpers.patterns_value(@selected)}
                diff_passed={ReviewReportHelpers.patterns_passed(@selected)}
                hooks={ReviewReportHelpers.pitfalls_value(@selected)}
                hooks_passed={ReviewReportHelpers.pitfalls_passed(@selected)}
              />

              <section
                :if={present_text?(@selected.completion_summary)}
                data-review-completion-summary
                style={[
                  "margin: 12px 16px 0; padding: 10px 12px;",
                  "border-radius: 6px;",
                  "background: var(--surface); border: 1px solid var(--line);",
                  "color: var(--ink); font-size: 12.5px; line-height: 1.5;",
                  "display: flex; flex-direction: column; gap: 6px;"
                ]}
              >
                <span style={[
                  "font-size: 11px; font-weight: 600; letter-spacing: 0.04em;",
                  "text-transform: uppercase; color: var(--ink-3);"
                ]}>
                  {gettext("Completion summary")}
                </span>
                <p style="margin: 0; white-space: pre-wrap;">
                  {@selected.completion_summary}
                </p>
              </section>

              <section
                data-review-issues
                style={[
                  "margin: 12px 16px 0; padding: 10px 12px;",
                  "border-radius: 6px;",
                  "background: var(--surface); border: 1px solid var(--line);",
                  "color: var(--ink); font-size: 12.5px; line-height: 1.5;",
                  "display: flex; flex-direction: column; gap: 6px;"
                ]}
              >
                <span style={[
                  "font-size: 11px; font-weight: 600; letter-spacing: 0.04em;",
                  "text-transform: uppercase; color: var(--ink-3);"
                ]}>
                  {gettext("Issues")}
                </span>
                <ReviewReportPanel.review_report_panel task={@selected} />
              </section>

              <section
                data-review-acceptance
                style={[
                  "margin: 12px 16px 0; padding: 10px 12px;",
                  "border-radius: 6px;",
                  "background: var(--surface); border: 1px solid var(--line);"
                ]}
              >
                <AcceptanceChecklist.acceptance_checklist
                  acceptance_criteria={@selected.acceptance_criteria}
                  checked={acceptance_checked(@selected)}
                  failed={acceptance_failed(@selected)}
                  structured={structured_acceptance(@selected)}
                />
              </section>

              <section
                data-review-changed-files
                style={[
                  "margin: 12px 16px 0; padding: 10px 12px;",
                  "border-radius: 6px;",
                  "background: var(--surface); border: 1px solid var(--line);",
                  "color: var(--ink); font-size: 12.5px; line-height: 1.5;",
                  "display: flex; flex-direction: column; gap: 6px;"
                ]}
              >
                <span style={[
                  "font-size: 11px; font-weight: 600; letter-spacing: 0.04em;",
                  "text-transform: uppercase; color: var(--ink-3);"
                ]}>
                  {gettext("Changed files")}
                </span>
                <ReviewDiffPanel.review_diff_panel
                  files={task_files(@selected)}
                  selected_file={selected_file_payload(@selected, @selected_changed_file)}
                  on_file_click="select_changed_file"
                />
              </section>

              <section
                :if={CodeReviewPanel.checks_for(@selected) != []}
                data-review-code-review-section
                style={[
                  "margin: 12px 16px 16px; padding: 10px 12px;",
                  "border-radius: 6px;",
                  "background: var(--surface); border: 1px solid var(--line);",
                  "color: var(--ink); font-size: 12.5px; line-height: 1.5;",
                  "display: flex; flex-direction: column; gap: 8px;"
                ]}
              >
                <span style={[
                  "font-size: 11px; font-weight: 600; letter-spacing: 0.04em;",
                  "text-transform: uppercase; color: var(--ink-3);"
                ]}>
                  {gettext("Code review")}
                </span>
                <CodeReviewPanel.code_review_panel task={@selected} />
              </section>
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

  # Pill rendered next to the summary blurb. Reads the schema 1.0
  # `reviewer_result.status` directly when present; otherwise derives the
  # verdict from whatever signals the reviewer did emit (any
  # `acceptance_criteria` item with `status: "not_met"` or a positive
  # legacy `issues_found` count → "changes_requested"; a dispatched
  # reviewer with no issues → "approved"). Returns `nil` only when the
  # reviewer was skipped or never ran, so the pill hides on those tasks.
  defp review_status_pill(task) do
    case derive_review_status(task) do
      "approved" ->
        %{
          status: "approved",
          label: gettext("Approved"),
          icon: "hero-check-circle",
          style:
            "background: var(--st-done-soft, oklch(96% 0.05 155)); " <>
              "color: var(--st-done, oklch(50% 0.14 155));"
        }

      "changes_requested" ->
        %{
          status: "changes_requested",
          label: gettext("Changes requested"),
          icon: "hero-arrow-uturn-left",
          style:
            "background: var(--st-blocked-soft, oklch(96% 0.04 25)); " <>
              "color: var(--st-blocked, oklch(50% 0.18 25));"
        }

      _ ->
        nil
    end
  end

  defp derive_review_status(%{reviewer_result: %{"status" => status}})
       when status in ["approved", "changes_requested"],
       do: status

  defp derive_review_status(%{reviewer_result: %{} = result}) do
    cond do
      any_not_met?(Map.get(result, "acceptance_criteria", [])) -> "changes_requested"
      is_integer(result["issues_found"]) and result["issues_found"] > 0 -> "changes_requested"
      result["dispatched"] == true -> "approved"
      true -> nil
    end
  end

  defp derive_review_status(_), do: nil

  defp any_not_met?(criteria) when is_list(criteria) do
    Enum.any?(criteria, fn
      %{"status" => "not_met"} -> true
      _ -> false
    end)
  end

  defp any_not_met?(_), do: false

  defp acceptance_value(task) do
    total = task.acceptance_criteria |> parse_lines() |> length()
    format_acceptance_value(task, total)
  end

  defp format_acceptance_value(_task, 0), do: nil

  defp format_acceptance_value(task, total) do
    if reviewer_dispatched?(task) do
      reviewer_acceptance_value(task, total)
    else
      Integer.to_string(total)
    end
  end

  # Reviewer ran — pick between the clean-pass and issues-found rendering.
  defp reviewer_acceptance_value(task, total) do
    checked = checked_count(task, total)
    n_issues = issues_found(task) || 0

    if n_issues > 0 do
      ngettext(
        "%{checked}/%{total} · %{n} issue",
        "%{checked}/%{total} · %{n} issues",
        n_issues,
        checked: checked,
        total: total,
        n: n_issues
      )
    else
      "#{checked}/#{total}"
    end
  end

  # Tone for the Acceptance cell. `true` → green, `false` → red, `nil` →
  # neutral. Derived strictly from the reviewer subagent's `issues_found`
  # count so that skipped or pre-subagent tasks render neutrally rather
  # than falsely-passing.
  defp acceptance_passed(task) do
    case {reviewer_dispatched?(task), issues_found(task)} do
      {true, 0} -> true
      {true, n} when is_integer(n) and n > 0 -> false
      _ -> nil
    end
  end

  # Mark each criterion row :met / :not_met / :unchecked. When the
  # `review_report` contains an "Acceptance criteria status" section, parse
  # it to derive per-row state. Falls back to "all rows checked" when the
  # reviewer ran and the bulk count matches `total` — i.e. the reviewer
  # covered everything but didn't itemise.
  defp acceptance_checked(task) do
    statuses = acceptance_status_map(task)

    if map_size(statuses) > 0 do
      statuses_to_bool_map(statuses, :met)
    else
      fallback_acceptance_checked(task)
    end
  end

  defp fallback_acceptance_checked(task) do
    total = task.acceptance_criteria |> parse_lines() |> length()

    if total > 0 and reviewer_dispatched?(task) and checked_count(task, total) == total do
      Map.new(0..(total - 1), &{&1, true})
    else
      %{}
    end
  end

  defp statuses_to_bool_map(statuses, target_status) do
    for {idx, status} <- statuses, status == target_status, into: %{}, do: {idx, true}
  end

  # Returns the structured `reviewer_result.acceptance_criteria` list when
  # the reviewer subagent supplied one. The checklist consumes this list
  # directly to render per-criterion verdict + evidence, bypassing the
  # raw-string parsing path.
  defp structured_acceptance(%{reviewer_result: %{"acceptance_criteria" => list}})
       when is_list(list),
       do: list

  defp structured_acceptance(_), do: []

  defp acceptance_failed(task) do
    task
    |> acceptance_status_map()
    |> statuses_to_bool_map(:not_met)
  end

  # Regexes used by the `acceptance_status_map/1` parser below. Defined
  # ABOVE the functions that reference them — module attributes are
  # evaluated at the point of definition during compilation, so a
  # forward-reference would expand to `nil` and blow up at runtime.
  @status_heading_regex ~r/acceptance\s+criteria\s+status/i
  @status_line_regex ~r/^(\d+)\.\s*(.+?)\s*[—–-]+\s*(Not\s+Met|Met)\.?\s*$/i

  # Parses the "Acceptance criteria status" section of `review_report` into
  # `%{index => :met | :not_met}`. Looks for the heading line and then for
  # subsequent numbered lines of the form `N. <text> — Met` (or "Not Met").
  # Returns `%{}` when the section is absent or the report is empty.
  defp acceptance_status_map(%{review_report: report}) when is_binary(report) and report != "" do
    report
    |> String.split(~r/\r?\n/)
    |> Enum.drop_while(fn line -> not Regex.match?(@status_heading_regex, line) end)
    |> tl_or_empty()
    |> Enum.reduce(%{}, &parse_status_line/2)
  end

  defp acceptance_status_map(_), do: %{}

  defp tl_or_empty([_ | rest]), do: rest
  defp tl_or_empty([]), do: []

  defp parse_status_line(line, acc) do
    trimmed = String.trim(line)

    cond do
      String.starts_with?(trimmed, "#") -> acc
      match = Regex.run(@status_line_regex, trimmed) -> insert_status(acc, match)
      true -> acc
    end
  end

  defp insert_status(acc, [_, num, _text, status]) do
    idx = String.to_integer(num) - 1
    status_atom = if String.match?(status, ~r/not/i), do: :not_met, else: :met
    Map.put(acc, idx, status_atom)
  end

  defp present_text?(s) when is_binary(s), do: String.trim(s) != ""
  defp present_text?(_), do: false

  defp reviewer_dispatched?(%{reviewer_result: %{"dispatched" => true}}), do: true
  defp reviewer_dispatched?(_), do: false

  defp issues_found(%{reviewer_result: %{"issues_found" => n}}) when is_integer(n), do: n
  defp issues_found(_), do: nil

  defp checked_count(%{reviewer_result: %{"acceptance_criteria_checked" => n}}, _total)
       when is_integer(n),
       do: n

  defp checked_count(_task, total), do: total

  defp parse_lines(nil), do: []

  defp parse_lines(text) when is_binary(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_lines(_), do: []

  # Builds the per-file payload passed to the diff panel. Looks up the
  # selected path in the task's persisted `changed_files` jsonb (see
  # `docs/diff-contract.md` for the shape). Falls back to a path-only
  # entry with `diff: nil` for legacy completion payloads that did not
  # carry per-file diff data — the panel renders "no diff available" in
  # that case.
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
