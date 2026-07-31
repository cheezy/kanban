defmodule KanbanWeb.ReviewReportHelpers.Tokens do
  @moduledoc """
  Presentation tokens for the review surfaces — status pills, verdict tones
  and icons, and the check-row shapes the Review queue and the task view
  render.

  Split out of `KanbanWeb.ReviewReportHelpers` (W2004), which had grown past
  the module-size guidance in `AGENTS.md`, and shaped after the existing
  `KanbanWeb.TaskTokens`. Everything here is display-only: it derives labels,
  icons and inline style strings, and reads verdicts through the parent
  module's public API rather than recomputing them.

  The dependency runs one way — this module calls the parent, never the
  reverse — so the split introduces no cycle. Every function is pure; no DB
  access, no scope resolution.
  """
  use Gettext, backend: KanbanWeb.Gettext

  alias KanbanWeb.ReviewReportHelpers

  # Sections rendered as generic check rows in the review report panel
  # (security_considerations gets its own dedicated row above these).
  @review_check_sections [:testing_strategy, :patterns, :pitfalls]

  @doc """
  Pill rendered next to the review summary blurb. The verdict is derived SOLELY
  from the structured `reviewer_result.status` field. When a review was
  dispatched but carries no recognized structured status (a legacy/thin
  `reviewer_result`), the pill renders a neutral "Review data unavailable" state
  — it never fabricates "changes_requested"/"approved" from legacy
  `issues_found` counts or `acceptance_criteria` heuristics (D56). Returns `nil`
  when the reviewer was skipped, never ran, or reported an unrecognized status.
  """
  @spec review_status_pill(map()) :: map() | nil
  def review_status_pill(task) do
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

      :unavailable ->
        %{
          status: "unavailable",
          label: gettext("Review data unavailable"),
          icon: "hero-question-mark-circle",
          style: "background: var(--surface-2); color: var(--ink-2);"
        }

      _ ->
        nil
    end
  end

  defp derive_review_status(%{reviewer_result: %{"status" => status}})
       when status in ["approved", "changes_requested"],
       do: status

  # A review was dispatched but carries no recognized structured status
  # (legacy/thin reviewer_result). Show a neutral "data unavailable" state
  # rather than inferring a verdict from legacy issues_found/acceptance
  # heuristics — those inferences are exactly what produced false
  # "Changes requested" pills (D56).
  defp derive_review_status(%{reviewer_result: %{"dispatched" => true}}), do: :unavailable

  defp derive_review_status(_), do: nil

  @doc """
  Maps a section verdict tone to the same soft-background / ink token pairs the
  review status pill uses, so the area stays legible in both light and dark mode
  (the tokens have per-theme definitions in app.css). `true` → green, `false` →
  red, anything else → neutral.
  """
  @spec verdict_tone_style(boolean() | nil) :: String.t()
  def verdict_tone_style(true) do
    "background: var(--st-done-soft, oklch(96% 0.05 155)); " <>
      "color: var(--st-done, oklch(50% 0.14 155));"
  end

  def verdict_tone_style(false) do
    "background: var(--st-blocked-soft, oklch(96% 0.04 25)); " <>
      "color: var(--st-blocked, oklch(50% 0.18 25));"
  end

  def verdict_tone_style(_), do: "background: var(--surface-2); color: var(--ink-2);"

  @doc """
  Hero icon name for a section verdict. Security keeps its shield iconography;
  generic check rows use neutral pass/fail/unknown circles.
  """
  @spec verdict_icon(atom(), boolean() | nil) :: String.t()
  def verdict_icon(:security_considerations, false), do: "hero-shield-exclamation"
  def verdict_icon(:security_considerations, _), do: "hero-shield-check"
  def verdict_icon(_section, true), do: "hero-check-circle"
  def verdict_icon(_section, false), do: "hero-x-circle"
  def verdict_icon(_section, _), do: "hero-question-mark-circle"

  @doc """
  A stable status key (`"passed"` / `"failed"` / `"not_assessed"`) for data
  attributes and tests, derived from the same pass/fail/neutral semantics as
  `verdict_tone_style/1`.
  """
  @spec section_status_key(map(), atom()) :: String.t()
  def section_status_key(task, section) do
    case section_passed(task, section) do
      true -> "passed"
      false -> "failed"
      _ -> "not_assessed"
    end
  end

  defp section_passed(task, :testing_strategy),
    do: ReviewReportHelpers.testing_strategy_passed(task)

  defp section_passed(task, :patterns), do: ReviewReportHelpers.patterns_passed(task)
  defp section_passed(task, :pitfalls), do: ReviewReportHelpers.pitfalls_passed(task)

  defp section_passed(task, :security_considerations),
    do: ReviewReportHelpers.security_considerations_passed(task)

  defp section_value(task, :testing_strategy),
    do: ReviewReportHelpers.testing_strategy_value(task)

  defp section_value(task, :patterns), do: ReviewReportHelpers.patterns_value(task)
  defp section_value(task, :pitfalls), do: ReviewReportHelpers.pitfalls_value(task)

  @doc """
  One map per renderable check row. A row is visible when it has a verdict
  value, a reviewer note, an incomplete flag, or a per-category breakdown —
  legacy tasks with none of these get no rows, and the section hides entirely.
  Pure; safe to call twice from the template (once for the section guard, once
  for `:for`).
  """
  @spec review_check_rows(map()) :: [map()]
  def review_check_rows(task) do
    @review_check_sections
    |> Enum.map(&review_check_row(task, &1))
    |> Enum.filter(fn row -> row.value || row.note || row.incomplete? || row.breakdown != [] end)
  end

  defp review_check_row(task, section) do
    %{
      section: section,
      label: ReviewReportHelpers.section_label(section),
      value: section_value(task, section),
      passed: section_passed(task, section),
      status: section_status_key(task, section),
      note: ReviewReportHelpers.section_note(task, section),
      incomplete?: ReviewReportHelpers.section_incomplete?(task, section),
      breakdown: section_breakdown(task, section)
    }
  end

  # The testing-strategy row expands into the task's own per-category strategy
  # entries; the other sections have no structured breakdown.
  defp section_breakdown(task, :testing_strategy),
    do: ReviewReportHelpers.testing_strategy_breakdown(task)

  defp section_breakdown(_task, _section), do: []

  @doc """
  Stable status key (`"passed"` / `"failed"` / `"not_assessed"`) for a
  per-category boolean verdict.
  """
  @spec category_status_key(boolean() | nil) :: String.t()
  def category_status_key(true), do: "passed"
  def category_status_key(false), do: "failed"
  def category_status_key(_), do: "not_assessed"

  @doc """
  Human-readable, translated verdict label for a per-category boolean verdict.
  """
  @spec category_verdict_label(boolean() | nil) :: String.t()
  def category_verdict_label(true), do: gettext("passed")
  def category_verdict_label(false), do: gettext("failed")
  def category_verdict_label(_), do: gettext("not assessed")
end
