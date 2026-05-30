defmodule KanbanWeb.ReviewReportPanel do
  @moduledoc """
  Shared review-report panel rendered across the Review Queue, the
  task-detail review section, and the agent-handoff completion view.

  Three render branches, gated on the task's `reviewer_result` and
  `review_report` fields:

    * **Structured** — when `reviewer_result["issues"]` is a list. Renders
      the status banner, prose summary, severity-grouped issue list,
      acceptance-criteria grid, and three section-verdict tiles
      (testing strategy, patterns, pitfalls) sourced directly from the
      structured payload. Emits the `[:kanban, :review, :structured_used]`
      telemetry event so the rollout can confirm the new path is reached.

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

    ~H"""
    <section
      :if={@branch != :empty}
      data-review-report-panel={Atom.to_string(@branch)}
      class="bg-base-100 border border-base-300 dark:border-base-content/15 rounded-lg p-4 text-base-content"
    >
      <%= case @branch do %>
        <% :structured -> %>
          <.structured_view reviewer_result={@reviewer_result} />
        <% :fallback -> %>
          <.fallback_view task={@task} review_report={@review_report} />
      <% end %>
    </section>
    """
  end

  # --- Structured branch ---------------------------------------------------

  attr :reviewer_result, :map, required: true

  defp structured_view(assigns) do
    assigns = assign(assigns, :issues, Map.get(assigns.reviewer_result, "issues", []))

    ~H"""
    <.issue_list issues={@issues} />
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
    assigns = assign(assigns, :report_html, render_markdown(assigns.review_report))

    ~H"""
    <div
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
      %{} = result -> map_size(result) > 0
      _ -> false
    end
  end

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
