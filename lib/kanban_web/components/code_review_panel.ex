defmodule KanbanWeb.CodeReviewPanel do
  @moduledoc """
  "CODE REVIEW" panel for the Review queue detail view at `/review`.

  Renders the project-level code-review checks the Stride task-reviewer agent
  emits against each task's diff. The full check list lives at
  `CODE-REVIEW.md` at the project root; the reviewer evaluates every bullet
  as `met` or `not_met` and sends the result back inside `reviewer_result`
  under the `"project_checks"` key (W: code-review-panel).

  Each entry has:

    * `"check"` — string. The check description, typically the verbatim
      `CODE-REVIEW.md` bullet (including `CRITICAL:` prefix when present).
    * `"status"` — `"met"` | `"not_met"` (anything else renders as a
      neutral pill labelled with the raw value).
    * `"evidence"` — optional string. The reviewer's proof: a file path,
      a quote, or a suggested fix. Omitted entries render the check
      without the secondary line.

  When the task has no `project_checks` (older completions, skipped
  reviewer, or a runtime that does not emit the array), the component
  renders nothing at all — the wrapping section in `review_live.ex` is
  gated on a non-empty list so the panel never shows an empty shell.
  """
  use KanbanWeb, :html

  @doc """
  Renders the CODE REVIEW panel for a task.

  ## Attrs

    * `task` — the task map. Reads `reviewer_result["project_checks"]`
      (also accepts a top-level atom `:reviewer_result`). When the key
      is absent or the list is empty, returns an empty rendering — the
      caller should gate the surrounding section accordingly via
      `KanbanWeb.CodeReviewPanel.checks_for/1`.
  """
  attr :task, :map, required: true

  def code_review_panel(assigns) do
    assigns = assign(assigns, :project_checks, checks_for(assigns.task))

    ~H"""
    <ul
      :if={@project_checks != []}
      data-review-code-review
      class="list-none p-0 m-0 flex flex-col gap-2"
    >
      <li :for={check <- @project_checks}>
        <.project_check_row check={check} />
      </li>
    </ul>
    """
  end

  @doc """
  Returns the project_checks list from a task. Useful for `:if` gating
  the surrounding section so the panel never renders an empty shell.
  """
  def checks_for(task) do
    case reviewer_result(task) do
      %{} = result -> Map.get(result, "project_checks", []) |> List.wrap()
      _ -> []
    end
  end

  defp reviewer_result(%{reviewer_result: result}) when is_map(result), do: result
  defp reviewer_result(%{"reviewer_result" => result}) when is_map(result), do: result
  defp reviewer_result(_), do: nil

  # --- Single check row ----------------------------------------------------

  attr :check, :map, required: true

  defp project_check_row(assigns) do
    status = Map.get(assigns.check, "status")

    assigns =
      assigns
      |> assign(:status, status)
      |> assign(:pill_style, project_check_status_style(status))
      |> assign(:status_label, project_check_status_label(status))
      |> assign(:check_text, Map.get(assigns.check, "check") || gettext("(no description)"))
      |> assign(:evidence, Map.get(assigns.check, "evidence"))

    ~H"""
    <div
      data-review-code-review-row
      data-review-code-review-status={@status || "unknown"}
      style={[
        "display: flex; flex-direction: column; gap: 4px;",
        "padding: 8px 10px; border-radius: 5px;",
        "background: var(--surface-2); border: 1px solid var(--line);"
      ]}
    >
      <div style="display: flex; align-items: flex-start; gap: 8px;">
        <span
          data-review-code-review-pill
          style={[
            "flex-shrink: 0; display: inline-flex; align-items: center;",
            "padding: 1px 7px; border-radius: 999px;",
            "font-size: 10.5px; font-weight: 600; letter-spacing: 0.02em;",
            "text-transform: uppercase; line-height: 1.5;",
            @pill_style
          ]}
        >
          {@status_label}
        </span>
        <span style="font-size: 12.5px; color: var(--ink); line-height: 1.45;">
          {@check_text}
        </span>
      </div>
      <p
        :if={is_binary(@evidence) and @evidence != ""}
        data-review-code-review-evidence
        style="margin: 0 0 0 calc(7px + 7px + 7px); font-size: 11.5px; color: var(--ink-3); line-height: 1.45;"
      >
        {@evidence}
      </p>
    </div>
    """
  end

  # Met → green soft bg + dark green ink; Not met → red soft bg + dark red ink;
  # unknown → neutral surface. Uses the W900-tuned status tokens so the pills
  # read in both themes.
  defp project_check_status_style("met"),
    do: "background: var(--st-done-soft); color: var(--st-done);"

  defp project_check_status_style("not_met"),
    do: "background: var(--st-blocked-soft); color: var(--st-blocked);"

  defp project_check_status_style(_),
    do: "background: var(--surface-sunken); color: var(--ink-2);"

  defp project_check_status_label("met"), do: gettext("Met")
  defp project_check_status_label("not_met"), do: gettext("Not met")
  defp project_check_status_label(other) when is_binary(other), do: other
  defp project_check_status_label(_), do: gettext("Unknown")
end
