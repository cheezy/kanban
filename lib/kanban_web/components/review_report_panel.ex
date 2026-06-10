defmodule KanbanWeb.ReviewReportPanel do
  @moduledoc """
  Shared review-report panel rendered across the Review Queue, the
  task-detail review section, and the agent-handoff completion view.

  Three render branches, gated on the task's `reviewer_result` and
  `review_report` fields:

    * **Structured** — when the payload carries structured content. Renders
      the reviewer's prose summary, the severity-grouped issue list, and the
      `review_report` markdown body (D62) sourced from the structured payload.
      The status pill, acceptance-criteria grid, and the per-section verdict
      tiles (testing strategy, patterns, pitfalls, security considerations) are
      owned by `ReviewLive`, not this panel. Emits the
      `[:kanban, :review, :structured_used]` telemetry event so the rollout can
      confirm the new path is reached.

    * **Fallback** — when `reviewer_result["issues"]` is absent but the
      legacy `review_report` markdown is present. Reuses
      `KanbanWeb.ReviewReportHelpers` (the same regex-based extractors the
      `ReviewLive` page uses) to derive the three verdict tiles, then
      renders the markdown body via Earmark. Emits
      `[:kanban, :review, :fallback_used]` so the leading indicator can
      track legacy-path renders.

    * **Empty** — both fields absent. Renders nothing, so callers can
      embed the component unconditionally.

  Purely presentational. Accept the task as an assign — do not call
  `Kanban.Repo` from inside the component.
  """
  use KanbanWeb, :html

  alias KanbanWeb.ReviewReportHelpers

  @doc """
  Renders the review-report panel for a task.

  ## Attrs

    * `task` — the task map. May contain a `:reviewer_result` map
      (preferred) and/or a `:review_report` markdown string. Both may be
      absent; the panel hides itself when neither is present.
  """
  attr :task, :map, required: true

  def review_report_panel(assigns) do
    branch = pick_branch(assigns.task)
    emit_telemetry(branch, assigns.task)

    assigns =
      assigns
      |> assign(:branch, branch)
      |> assign(:reviewer_result, reviewer_result(assigns.task))
      |> assign(:review_report, review_report(assigns.task))
      |> assign(:incomplete_sections, ReviewReportHelpers.incomplete_sections(assigns.task))

    ~H"""
    <section
      :if={@branch != :empty}
      data-review-report-panel={Atom.to_string(@branch)}
      class="bg-base-100 border border-base-300 dark:border-base-content/15 rounded-lg p-4 text-base-content"
    >
      <div
        :if={@incomplete_sections != []}
        data-review-report-incomplete
        class="flex items-start gap-2 mb-3 p-2 rounded border border-warning bg-base-200 text-sm text-base-content"
      >
        <.icon name="hero-exclamation-triangle" class="w-4 h-4 flex-shrink-0 text-warning" />
        <span>
          {gettext(
            "Incomplete review — the task specified these sections, but the review did not assess them:"
          )} {Enum.map_join(@incomplete_sections, ", ", &ReviewReportHelpers.section_label/1)}
        </span>
      </div>
      <%= case @branch do %>
        <% :structured -> %>
          <.structured_view reviewer_result={@reviewer_result} review_report={@review_report} />
        <% :fallback -> %>
          <.fallback_view task={@task} review_report={@review_report} />
      <% end %>
    </section>
    """
  end

  # --- Structured branch ---------------------------------------------------

  attr :reviewer_result, :map, required: true
  attr :review_report, :string, default: nil

  # The structured branch now surfaces the reviewer's narrative — the summary
  # and the longer review_report body — alongside the issue list. Previously it
  # rendered only the issue list, so an approved review with no issues showed
  # just "No issues" and the write-up was invisible (D62). The summary is
  # rendered as escaped text; the report body reuses render_markdown/1 exactly
  # as the fallback branch does (and the two branches are mutually exclusive, so
  # the body is never rendered twice).
  defp structured_view(assigns) do
    assigns =
      assigns
      |> assign(:issues, Map.get(assigns.reviewer_result, "issues"))
      |> assign(:summary, Map.get(assigns.reviewer_result, "summary"))
      |> assign(:report_html, assigns.review_report |> strip_json_blocks() |> render_markdown())

    ~H"""
    <p
      :if={is_binary(@summary) and @summary != ""}
      data-review-report-summary
      class="text-sm text-base-content mb-3"
    >
      {@summary}
    </p>
    <.issue_list :if={is_list(@issues)} issues={@issues} />
    <div
      :if={@report_html != ""}
      data-review-report-body
      class="prose prose-sm max-w-none text-base-content mt-3"
    >
      {Phoenix.HTML.raw(@report_html)}
    </div>
    """
  end

  attr :issues, :list, required: true

  defp issue_list(assigns) do
    grouped = group_issues_by_severity(assigns.issues)
    assigns = assign(assigns, :grouped, grouped)

    ~H"""
    <div :if={@issues != []} data-review-report-issues class="space-y-3">
      <.issue_group
        :for={severity <- [:critical, :important, :minor]}
        severity={severity}
        issues={Map.get(@grouped, severity, [])}
      />
    </div>
    <p
      :if={@issues == []}
      data-review-report-issues-empty
      class="text-sm text-base-content opacity-60"
    >
      {gettext("No issues")}
    </p>
    """
  end

  attr :severity, :atom, required: true
  attr :issues, :list, required: true

  defp issue_group(assigns) do
    ~H"""
    <section
      :if={@issues != []}
      data-review-report-issue-group={Atom.to_string(@severity)}
      class="border-l-4 pl-3 border-base-300"
    >
      <h3 class={[
        "text-xs font-semibold uppercase tracking-wide mb-1",
        severity_text_class(@severity)
      ]}>
        {severity_label(@severity)} ({length(@issues)})
      </h3>
      <ul class="space-y-1 text-sm">
        <li :for={issue <- @issues} data-review-report-issue>
          <span :if={Map.get(issue, "category")} class="font-medium">
            {category_label(Map.get(issue, "category"))}:
          </span>
          <span>{Map.get(issue, "description") || gettext("(no description)")}</span>
        </li>
      </ul>
    </section>
    """
  end

  # --- Fallback branch -----------------------------------------------------

  attr :task, :map, required: true
  attr :review_report, :string, required: true

  defp fallback_view(assigns) do
    assigns =
      assign(
        assigns,
        :report_html,
        assigns.review_report |> strip_json_blocks() |> render_markdown()
      )

    ~H"""
    <div
      :if={@report_html != ""}
      data-review-report-fallback-body
      class="prose prose-sm max-w-none text-base-content"
    >
      {Phoenix.HTML.raw(@report_html)}
    </div>
    """
  end

  # --- Branch detection ----------------------------------------------------

  defp pick_branch(task) do
    cond do
      structured?(task) -> :structured
      fallback?(task) -> :fallback
      true -> :empty
    end
  end

  # The structured branch fires whenever `reviewer_result` carries ANY
  # structured payload — a list of issues, the dispatched/skip envelope,
  # acceptance criteria, or section verdicts. The structured_view
  # conditionally hides each subsection, so a sparse reviewer_result
  # (e.g. a skip-form with just `dispatched: false`, `reason`, `summary`)
  # renders a minimal panel with only its summary. This keeps skip-form
  # tasks visible after wiring into ReviewLive.
  defp structured?(task) do
    case reviewer_result(task) do
      %{} = result -> rich_content?(result) or skip_form?(result)
      _ -> false
    end
  end

  # Rich structured content the panel can render or trust directly: a verdict
  # status, a schema_version, an issue_counts map, a list of issues, an
  # acceptance-criteria list, or a per-section verdict object — i.e. the
  # structured reviewer schema. A thin/legacy reviewer_result (e.g.
  # %{"dispatched" => true, "issues_found" => 2}, only scalar counts and a
  # prose summary) has NONE of these and must NOT win the structured branch —
  # it falls through to the legacy review_report markdown (fallback) instead of
  # rendering "No issues" and suppressing the report (D59).
  defp rich_content?(result) do
    is_binary(Map.get(result, "status")) or
      is_binary(Map.get(result, "schema_version")) or
      is_map(Map.get(result, "issue_counts")) or
      is_list(Map.get(result, "issues")) or
      is_list(Map.get(result, "acceptance_criteria")) or
      section_verdict?(result)
  end

  defp section_verdict?(result) do
    Enum.any?(["testing_strategy", "patterns", "pitfalls", "security_considerations"], fn key ->
      case Map.get(result, key) do
        %{"status" => status} when is_binary(status) -> true
        _ -> false
      end
    end)
  end

  # A skipped review (dispatched: false) keeps the structured branch so its
  # summary still renders (never collapses to "No issues").
  defp skip_form?(%{"dispatched" => false}), do: true
  defp skip_form?(_), do: false

  defp fallback?(task) do
    report = review_report(task)
    is_binary(report) and report != ""
  end

  defp reviewer_result(%{reviewer_result: result}) when is_map(result), do: result
  defp reviewer_result(%{"reviewer_result" => result}) when is_map(result), do: result
  defp reviewer_result(_), do: nil

  defp review_report(%{review_report: report}) when is_binary(report), do: report
  defp review_report(%{"review_report" => report}) when is_binary(report), do: report
  defp review_report(_), do: nil

  # --- Telemetry -----------------------------------------------------------

  defp emit_telemetry(:structured, task) do
    :telemetry.execute(
      [:kanban, :review, :structured_used],
      %{count: 1},
      telemetry_metadata(task)
    )
  end

  defp emit_telemetry(:fallback, task) do
    :telemetry.execute(
      [:kanban, :review, :fallback_used],
      %{count: 1},
      telemetry_metadata(task)
    )
  end

  defp emit_telemetry(:empty, _task), do: :ok

  defp telemetry_metadata(task) do
    %{
      task_id: Map.get(task, :id) || Map.get(task, "id"),
      identifier: Map.get(task, :identifier) || Map.get(task, "identifier")
    }
  end

  # --- Markdown ------------------------------------------------------------

  defp render_markdown(text) when is_binary(text) do
    case Earmark.as_html(text, smartypants: false) do
      {:ok, html, _warnings} -> html
      {:error, html, _warnings} -> html
    end
  end

  defp render_markdown(_), do: ""

  # --- JSON-fence stripping (D64) -------------------------------------------

  # Agent-submitted review_report strings embed a fenced ```json copy of the
  # structured reviewer output. That payload is machine-facing — the same data
  # already renders as the summary, issue list, and section verdicts — so it
  # is removed from the markdown before rendering. Display-only: the stored
  # review_report keeps its JSON block for API consumers. Fences with other
  # language tags survive; untagged fences are removed only when their content
  # parses as a JSON object.
  @fence_close ~r/^```[ \t]*$/
  @fence_json ~r/^```json[ \t]*$/
  @fence_tagged ~r/^```\S/

  defp strip_json_blocks(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> drop_json_fences(:outside, [])
    |> Enum.reverse()
    |> Enum.join("\n")
    |> String.trim()
  end

  defp strip_json_blocks(other), do: other

  # Line-by-line state machine. `kept` accumulates retained lines in reverse.
  # An unclosed ```json fence at end-of-input stays dropped; an unclosed
  # untagged fence is kept verbatim (its buffer is flushed back).
  defp drop_json_fences([], {:untagged, buffer}, kept), do: buffer ++ kept
  defp drop_json_fences([], _state, kept), do: kept

  defp drop_json_fences([line | rest], :outside, kept) do
    case classify_fence_line(line) do
      :json_open -> drop_json_fences(rest, :json, kept)
      :untagged_open -> drop_json_fences(rest, {:untagged, [line]}, kept)
      :tagged_open -> drop_json_fences(rest, :kept_fence, [line | kept])
      :text -> drop_json_fences(rest, :outside, [line | kept])
    end
  end

  defp drop_json_fences([line | rest], :json, kept) do
    if Regex.match?(@fence_close, line),
      do: drop_json_fences(rest, :outside, kept),
      else: drop_json_fences(rest, :json, kept)
  end

  defp drop_json_fences([line | rest], :kept_fence, kept) do
    next_state = if Regex.match?(@fence_close, line), do: :outside, else: :kept_fence
    drop_json_fences(rest, next_state, [line | kept])
  end

  defp drop_json_fences([line | rest], {:untagged, buffer}, kept) do
    if Regex.match?(@fence_close, line),
      do: drop_json_fences(rest, :outside, close_untagged_fence(line, buffer, kept)),
      else: drop_json_fences(rest, {:untagged, [line | buffer]}, kept)
  end

  defp classify_fence_line(line) do
    cond do
      Regex.match?(@fence_json, line) -> :json_open
      Regex.match?(@fence_close, line) -> :untagged_open
      Regex.match?(@fence_tagged, line) -> :tagged_open
      true -> :text
    end
  end

  # A closed untagged fence is dropped only when its content is a JSON object;
  # anything else is flushed back into the kept lines verbatim.
  defp close_untagged_fence(line, buffer, kept) do
    if json_content?(buffer), do: kept, else: [line | buffer ++ kept]
  end

  # `buffer` is reverse-ordered with the opening fence as its last element.
  defp json_content?(buffer) do
    content =
      buffer
      |> Enum.reverse()
      |> tl()
      |> Enum.join("\n")
      |> String.trim()

    String.starts_with?(content, "{") and match?({:ok, _}, Jason.decode(content))
  end

  # --- Severity / status labels and styles ---------------------------------

  defp group_issues_by_severity(issues) when is_list(issues) do
    Enum.group_by(issues, fn issue ->
      case Map.get(issue, "severity") do
        "critical" -> :critical
        "important" -> :important
        "minor" -> :minor
        _ -> :minor
      end
    end)
  end

  defp severity_label(:critical), do: gettext("Critical")
  defp severity_label(:important), do: gettext("Important")
  defp severity_label(:minor), do: gettext("Minor")

  defp severity_text_class(:critical), do: "text-error"
  defp severity_text_class(:important), do: "text-warning"
  defp severity_text_class(_), do: "text-base-content opacity-70"

  defp category_label("acceptance_criteria"), do: gettext("Acceptance")
  defp category_label("pitfall"), do: gettext("Pitfalls")
  defp category_label("pattern"), do: gettext("Patterns")
  defp category_label("testing"), do: gettext("Testing")
  defp category_label("code_quality"), do: gettext("Code quality")
  defp category_label("project_check"), do: gettext("Project check")
  defp category_label(other) when is_binary(other), do: other
  defp category_label(_), do: ""
end
