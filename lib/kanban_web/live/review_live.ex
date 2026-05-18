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
  def handle_event("deselect_item", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected, nil)
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
                  "font-size: 13px; line-height: 1.55; color: var(--ink);"
                ]}
              >
                {summary_text(@selected)}
              </div>

              <ReviewStatsStrip.review_stats_strip
                acceptance={acceptance_value(@selected)}
                acceptance_passed={acceptance_passed(@selected)}
                tests={testing_strategy_value(@selected)}
                tests_passed={testing_strategy_passed(@selected)}
                diff={patterns_value(@selected)}
                diff_passed={patterns_passed(@selected)}
                hooks={pitfalls_value(@selected)}
                hooks_passed={pitfalls_passed(@selected)}
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

              <ReviewDiffPanel.review_diff_panel files={parse_files(@selected.actual_files_changed)} />

              <section
                :if={review_report_html(@selected)}
                data-review-report
                class="stride-review-report"
                style={[
                  "margin: 12px 16px 0; padding: 12px 14px;",
                  "border-radius: 6px;",
                  "background: var(--surface-sunken);",
                  "border: 1px solid var(--line);",
                  "color: var(--ink); font-size: 12.5px; line-height: 1.55;"
                ]}
              >
                {Phoenix.HTML.raw(review_report_html(@selected))}
              </section>

              <div style="padding: 12px 16px;">
                <AcceptanceChecklist.acceptance_checklist
                  acceptance_criteria={@selected.acceptance_criteria}
                  checked={acceptance_checked(@selected)}
                  failed={acceptance_failed(@selected)}
                />
              </div>
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

  # Renders the structured `review_report` as styled HTML via Earmark. Falls
  # back to the reviewer subagent's prose `summary` when there is no
  # report. Returns `nil` when neither is present, so the panel hides.
  defp review_report_html(%{review_report: report}) when is_binary(report) and report != "" do
    render_markdown(report)
  end

  defp review_report_html(%{reviewer_result: %{"dispatched" => true, "summary" => s}})
       when is_binary(s) and s != "" do
    # No structured report — render the prose summary as a single paragraph.
    render_markdown("### " <> gettext("Reviewer notes") <> "\n\n" <> s)
  end

  defp review_report_html(_), do: nil

  defp render_markdown(text) do
    case Earmark.as_html(text, smartypants: false) do
      {:ok, html, _warnings} -> html
      {:error, html, _warnings} -> html
    end
  end

  # --- Testing strategy + Patterns & Pitfalls strip helpers ----------------
  #
  # These four helpers parse the report's "Required test cases", "Patterns
  # followed", and "Pitfalls" sections to populate the two corresponding
  # cells in the stats strip. Tone is green when the reviewer signed off,
  # red when violations are called out, and neutral when the section is
  # missing — the cell goes back to its em-dash default.

  defp testing_strategy_value(task) do
    case report_section(task, ~r/required\s+test\s+cases|testing\s+strategy/i) do
      nil ->
        nil

      body ->
        n = count_list_items(body)

        cond do
          # Heading text often includes "(all present)" — surface that
          # phrase as the cell value so it matches the report's wording.
          all_present_heading?(task, ~r/required\s+test\s+cases|testing\s+strategy/i) ->
            ngettext(
              "%{n} case · all present",
              "%{n} cases · all present",
              n,
              n: n
            )

          n > 0 ->
            ngettext("%{n} case", "%{n} cases", n, n: n)

          true ->
            gettext("reviewed")
        end
    end
  end

  defp testing_strategy_passed(task) do
    cond do
      all_present_heading?(task, ~r/required\s+test\s+cases|testing\s+strategy/i) -> true
      report_section(task, ~r/required\s+test\s+cases|testing\s+strategy/i) -> true
      true -> nil
    end
  end

  defp patterns_value(task) do
    case report_section(task, ~r/patterns\s+followed/i) do
      nil -> nil
      _body -> gettext("followed")
    end
  end

  defp patterns_passed(task) do
    if report_section(task, ~r/patterns\s+followed/i), do: true, else: nil
  end

  defp pitfalls_value(task) do
    case report_section(task, ~r/pitfalls/i) do
      nil ->
        nil

      body ->
        if pitfalls_violated?(body) do
          gettext("violated")
        else
          gettext("none violated")
        end
    end
  end

  defp pitfalls_passed(task) do
    case report_section(task, ~r/pitfalls/i) do
      nil -> nil
      body -> not pitfalls_violated?(body)
    end
  end

  # Extracts the body of a markdown heading matching the given regex —
  # everything between the matched `###`/`##` line and the next heading.
  # Returns `nil` when the report is missing or the section is absent.
  defp report_section(%{review_report: report}, heading_regex)
       when is_binary(report) and report != "" do
    report
    |> String.split(~r/\r?\n/)
    |> Enum.split_while(fn line -> not heading_match?(line, heading_regex) end)
    |> extract_section_body()
  end

  defp report_section(_, _), do: nil

  defp extract_section_body({_, []}), do: nil

  defp extract_section_body({_, [_heading | rest]}) do
    rest
    |> Enum.take_while(fn line -> not heading_line?(line) end)
    |> Enum.join("\n")
    |> String.trim()
    |> nil_if_empty()
  end

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(text), do: text

  defp heading_match?(line, regex) do
    trimmed = String.trim(line)
    String.starts_with?(trimmed, "#") and Regex.match?(regex, trimmed)
  end

  defp heading_line?(line), do: line |> String.trim() |> String.starts_with?("#")

  # True when the section's heading text contains an "all present" /
  # "all covered" affordance — reviewers use this to signal full coverage
  # without having to spell out per-case verdicts.
  defp all_present_heading?(%{review_report: report}, regex)
       when is_binary(report) and report != "" do
    report
    |> String.split(~r/\r?\n/)
    |> Enum.any?(fn line ->
      trimmed = String.trim(line)

      String.starts_with?(trimmed, "#") and Regex.match?(regex, trimmed) and
        Regex.match?(~r/all\s+(present|covered|met)/i, trimmed)
    end)
  end

  defp all_present_heading?(_, _), do: false

  # Counts markdown list items (`- `, `* `, or `N. `) in a body string.
  defp count_list_items(body) when is_binary(body) do
    body
    |> String.split(~r/\r?\n/)
    |> Enum.count(fn line ->
      trimmed = String.trim_leading(line)

      String.starts_with?(trimmed, "- ") or String.starts_with?(trimmed, "* ") or
        Regex.match?(~r/^\d+\.\s+/, trimmed)
    end)
  end

  defp count_list_items(_), do: 0

  defp pitfalls_violated?(body) when is_binary(body) do
    cond do
      # Explicit "none violated" / "no violations" / "all honored" wins.
      Regex.match?(~r/(none\s+violated|no\s+violations|all\s+(honored|honoured))/i, body) ->
        false

      # Otherwise look for explicit violation language.
      Regex.match?(~r/(violated|violations?)/i, body) ->
        true

      true ->
        false
    end
  end

  defp pitfalls_violated?(_), do: false

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
