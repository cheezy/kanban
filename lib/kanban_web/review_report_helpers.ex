defmodule KanbanWeb.ReviewReportHelpers do
  @moduledoc """
  Regex-based extractors for the legacy markdown `review_report` field on a
  task. Centralises the parsing logic so both `KanbanWeb.ReviewLive` and the
  shared `KanbanWeb.ReviewReportPanel` component can derive the testing,
  patterns, pitfalls, and security-considerations verdict cells from the same
  source of truth.

  Every function is pure. Pass a map that may contain a `:review_report`
  string key (the LiveView struct) or a binary `"review_report"` key (raw
  task map). Functions return `nil` when the section is missing, so callers
  can render an em-dash default.
  """
  use Gettext, backend: KanbanWeb.Gettext

  alias Kanban.Tasks.CompletionValidation

  @incomplete_sections [:testing_strategy, :patterns, :pitfalls, :security_considerations]

  # Sections rendered as generic check rows in the review report panel
  # (security_considerations gets its own dedicated row above these).
  @review_check_sections [:testing_strategy, :patterns, :pitfalls]

  @doc """
  Returns `true` when a review section is a genuine gap: the task supplied
  content for it, but the review left it missing or `not_assessed`. Drives the
  loud incomplete-section warnings on the Review queue (W1071). A section the
  task did not supply is never flagged — only true gaps. Pure; no DB access.
  """
  def section_incomplete?(task, section) when section in @incomplete_sections do
    section_supplied?(task, section) and
      effective_section_status(task, section) in [
        nil,
        "not_assessed"
      ]
  end

  def section_incomplete?(_task, _section), do: false

  @doc """
  The list of section atoms the task supplied but the review left missing or
  unassessed — the sections the Review queue should warn about.
  """
  def incomplete_sections(task) do
    Enum.filter(@incomplete_sections, &section_incomplete?(task, &1))
  end

  @doc "Human-readable label for an incomplete review section."
  def section_label(:testing_strategy), do: gettext("Testing strategy")
  def section_label(:patterns), do: gettext("Patterns")
  def section_label(:pitfalls), do: gettext("Pitfalls")
  def section_label(:security_considerations), do: gettext("Security considerations")

  @doc """
  The reviewer's note string for one of the four review sections
  (`:testing_strategy`, `:patterns`, `:pitfalls`, `:security_considerations`).

  Reads the structured `reviewer_result[section]["note"]` the reviewer agent
  emits alongside each section status and returns the trimmed string, or
  `nil` when the reviewer_result, the section map, or the note is missing,
  blank, or not a binary. Tolerates both atom-keyed and string-keyed task
  maps, matching the module's other accessors. Pure; no DB access.
  """
  def section_note(task, section) when section in @incomplete_sections do
    case reviewer_result(task) do
      %{} = result -> result |> Map.get(Atom.to_string(section)) |> note_from_section()
      _ -> nil
    end
  end

  def section_note(_task, _section), do: nil

  defp note_from_section(%{"note" => note}) when is_binary(note) do
    case String.trim(note) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp note_from_section(_), do: nil

  @doc """
  True when the task has anything the review panel can render — a non-empty
  structured `reviewer_result` or a non-empty `review_report` markdown
  string. Drives panel visibility in both the task edit form and the
  read-only task view (W1085). Pure; no DB access.
  """
  def review_panel_visible?(task) do
    has_reviewer_result?(task) or has_review_report?(task)
  end

  @doc """
  True when the task carries a non-empty `reviewer_result` map.
  """
  def has_reviewer_result?(%{reviewer_result: %{} = result}), do: map_size(result) > 0
  def has_reviewer_result?(_), do: false

  @doc """
  True when the task carries a non-empty `review_report` binary (whitespace
  counts as content, matching the original predicate).
  """
  def has_review_report?(%{review_report: report}) when is_binary(report) and report != "",
    do: true

  def has_review_report?(_), do: false

  @doc """
  The project-checks coverage gap for a dispatched review: `{supplied, expected}`
  when the review's `project_checks` covers fewer than the canonical checklist
  (`CODE-REVIEW.md`) expects, or `nil` when the coverage is complete, the review
  was not dispatched, or the checklist count is unavailable. Drives the Code
  Review panel's incomplete warning (W1071). Pure; the expected count is the
  compile-time-baked checklist size, not a DB read.
  """
  def project_checks_gap(task) do
    with %{"dispatched" => true} = result <- reviewer_result(task),
         expected when is_integer(expected) and expected > 0 <-
           CompletionValidation.project_checklist_count() do
      coverage_gap(result, expected)
    else
      _ -> nil
    end
  end

  defp coverage_gap(result, expected) do
    supplied = result |> Map.get("project_checks", []) |> List.wrap() |> length()
    if supplied < expected, do: {supplied, expected}, else: nil
  end

  defp effective_section_status(task, :testing_strategy),
    do:
      structured_or_derived(task, "testing_strategy", "testing", testing_strategy_present?(task))

  defp effective_section_status(task, :patterns),
    do: structured_or_derived(task, "patterns", "pattern", patterns_present?(task))

  defp effective_section_status(task, :pitfalls),
    do: structured_or_derived(task, "pitfalls", "pitfall", pitfalls_present?(task))

  defp effective_section_status(task, :security_considerations),
    do:
      structured_or_derived(
        task,
        "security_considerations",
        "security",
        security_considerations_present?(task)
      )

  defp section_supplied?(task, :testing_strategy), do: testing_strategy_present?(task)
  defp section_supplied?(task, :patterns), do: patterns_present?(task)
  defp section_supplied?(task, :pitfalls), do: pitfalls_present?(task)

  defp section_supplied?(task, :security_considerations),
    do: security_considerations_present?(task)

  @doc """
  Human-readable value for the testing-strategy verdict cell.

  Prefers the structured `reviewer_result["testing_strategy"]["status"]`
  when present; falls back to regex extraction from `review_report`.
  Returns a localized string or `nil` when no source has a value.
  """
  def testing_strategy_value(task) do
    case structured_or_derived(
           task,
           "testing_strategy",
           "testing",
           testing_strategy_present?(task)
         ) do
      nil -> testing_strategy_value_from_report(task)
      status -> structured_status_label(status)
    end
  end

  defp testing_strategy_value_from_report(task) do
    case report_section(task, ~r/required\s+test\s+cases|testing\s+strategy/i) do
      nil ->
        nil

      body ->
        n = count_list_items(body)

        cond do
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

  @doc """
  Tone toggle for the testing-strategy verdict cell. Prefers structured
  `reviewer_result["testing_strategy"]["status"]` when present; falls back
  to the regex path. Returns `true`/`false`/`nil`.
  """
  def testing_strategy_passed(task) do
    case structured_or_derived(
           task,
           "testing_strategy",
           "testing",
           testing_strategy_present?(task)
         ) do
      nil -> testing_strategy_passed_from_report(task)
      status -> structured_status_passed(status)
    end
  end

  defp testing_strategy_passed_from_report(task) do
    cond do
      all_present_heading?(task, ~r/required\s+test\s+cases|testing\s+strategy/i) -> true
      report_section(task, ~r/required\s+test\s+cases|testing\s+strategy/i) -> true
      true -> nil
    end
  end

  @testing_strategy_categories ~w(unit_tests integration_tests manual_tests edge_cases coverage_target)

  @doc """
  Per-category breakdown of the task's own `testing_strategy` field for the
  Review checks panel. Returns one map per non-empty category, in the fixed
  order unit_tests → integration_tests → manual_tests → edge_cases →
  coverage_target:

      %{key: "unit_tests", label: "Unit tests", items: ["..."], passed: true}

  `items` is the category's list of strings; `coverage_target` (a single
  string) becomes a one-item list. `passed` prefers a per-category verdict
  at `reviewer_result["testing_strategy"]["categories"][key]["status"]`
  when the reviewer supplied one, and falls back to the section-level
  testing-strategy verdict so each category shows the most specific status
  available. Returns `[]` when the task carries no testing strategy.
  """
  def testing_strategy_breakdown(task) do
    case fetch_field(task, :testing_strategy) do
      %{} = strategy when map_size(strategy) > 0 ->
        @testing_strategy_categories
        |> Enum.map(&breakdown_category(task, strategy, &1))
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp breakdown_category(task, strategy, key) do
    case category_items(Map.get(strategy, key)) do
      [] ->
        nil

      items ->
        %{key: key, label: category_label(key), items: items, passed: category_passed(task, key)}
    end
  end

  defp category_items(value) when is_binary(value) do
    case String.trim(value) do
      "" -> []
      trimmed -> [trimmed]
    end
  end

  defp category_items(value) when is_list(value) do
    value
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp category_items(_), do: []

  defp category_label("unit_tests"), do: gettext("Unit tests")
  defp category_label("integration_tests"), do: gettext("Integration tests")
  defp category_label("manual_tests"), do: gettext("Manual tests")
  defp category_label("edge_cases"), do: gettext("Edge cases")
  defp category_label("coverage_target"), do: gettext("Coverage target")

  defp category_passed(task, key) do
    case category_status(task, key) do
      nil -> testing_strategy_passed(task)
      status -> structured_status_passed(status)
    end
  end

  defp category_status(task, key) do
    with %{} = result <- reviewer_result(task),
         %{"categories" => %{} = categories} <- Map.get(result, "testing_strategy"),
         %{"status" => status} when is_binary(status) <- Map.get(categories, key) do
      status
    else
      _ -> nil
    end
  end

  @doc """
  Human-readable value for the patterns verdict cell. Prefers structured
  `reviewer_result["patterns"]["status"]` when present; falls back to the
  regex `Patterns followed` section in `review_report`.
  """
  def patterns_value(task) do
    case structured_or_derived(task, "patterns", "pattern", patterns_present?(task)) do
      nil ->
        case report_section(task, ~r/patterns\s+followed/i) do
          nil -> nil
          _body -> gettext("followed")
        end

      status ->
        structured_status_label(status)
    end
  end

  @doc """
  Tone toggle for the patterns verdict cell. Prefers structured field;
  falls back to regex.
  """
  def patterns_passed(task) do
    case structured_or_derived(task, "patterns", "pattern", patterns_present?(task)) do
      nil ->
        if report_section(task, ~r/patterns\s+followed/i), do: true, else: nil

      status ->
        structured_status_passed(status)
    end
  end

  @doc """
  Human-readable value for the pitfalls verdict cell. Prefers structured
  `reviewer_result["pitfalls"]["status"]` when present; falls back to the
  regex `Pitfalls` section in `review_report`.
  """
  def pitfalls_value(task) do
    case structured_or_derived(task, "pitfalls", "pitfall", pitfalls_present?(task)) do
      nil ->
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

      status ->
        structured_status_label(status)
    end
  end

  @doc """
  Tone toggle for the pitfalls verdict cell. Prefers structured field;
  falls back to regex.
  """
  def pitfalls_passed(task) do
    case structured_or_derived(task, "pitfalls", "pitfall", pitfalls_present?(task)) do
      nil ->
        case report_section(task, ~r/pitfalls/i) do
          nil -> nil
          body -> not pitfalls_violated?(body)
        end

      status ->
        structured_status_passed(status)
    end
  end

  @doc """
  Human-readable value for the security-considerations verdict cell. Prefers
  structured `reviewer_result["security_considerations"]["status"]` when
  present; otherwise derives a verdict from the categorized `issues` list.
  Returns a localized string or `nil` — there is no legacy `review_report`
  regex section for security considerations, so a thin/legacy payload yields
  `nil` and the caller renders an em-dash default.
  """
  def security_considerations_value(task) do
    case structured_or_derived(
           task,
           "security_considerations",
           "security",
           security_considerations_present?(task)
         ) do
      nil -> nil
      status -> structured_status_label(status)
    end
  end

  @doc """
  Tone toggle for the security-considerations verdict cell. Prefers the
  structured field, otherwise derives from the issues list. Returns
  `true`/`false`/`nil`, keeping neutral (`nil`) tone for absent verdicts.
  """
  def security_considerations_passed(task) do
    case structured_or_derived(
           task,
           "security_considerations",
           "security",
           security_considerations_present?(task)
         ) do
      nil -> nil
      status -> structured_status_passed(status)
    end
  end

  # --- Structured-field lookup --------------------------------------------

  defp structured_section_status(task, key) do
    case reviewer_result(task) do
      %{} = result ->
        case Map.get(result, key) do
          %{"status" => status} when is_binary(status) -> status
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Resolves a section status from the structured `reviewer_result[key].status`
  # first, then — when that is absent — derives one from the structured
  # `reviewer_result["issues"]` list (a verdict the reviewer agent emits today),
  # so the section verdict cells render even when the reviewer did not emit an
  # explicit per-section status object. Returns `nil` only when neither source
  # has a value, so the caller can still fall back to legacy regex extraction.
  defp structured_or_derived(task, key, category, metadata_present?) do
    structured_section_status(task, key) ||
      issues_derived_status(task, category, metadata_present?)
  end

  # Derives a section verdict from the categorized issues[] list:
  #   * a matching-category issue → "failed"
  #   * no matching issue, but the task carried that metadata → "passed"
  #   * no matching issue and no metadata → "not_assessed"
  # Returns `nil` when reviewer_result has no `issues` list, so callers fall
  # through to the regex path for legacy/thin payloads.
  defp issues_derived_status(task, category, metadata_present?) do
    case reviewer_result(task) do
      %{"issues" => issues} when is_list(issues) ->
        cond do
          Enum.any?(issues, fn issue -> issue_category(issue) == category end) -> "failed"
          metadata_present? -> "passed"
          true -> "not_assessed"
        end

      _ ->
        nil
    end
  end

  defp issue_category(%{"category" => category}), do: category
  defp issue_category(%{category: category}), do: category
  defp issue_category(_), do: nil

  defp testing_strategy_present?(task), do: present_map?(fetch_field(task, :testing_strategy))
  defp patterns_present?(task), do: present_string?(fetch_field(task, :patterns_to_follow))
  defp pitfalls_present?(task), do: present_list?(fetch_field(task, :pitfalls))

  defp security_considerations_present?(task),
    do: present_list?(fetch_field(task, :security_considerations))

  defp fetch_field(task, key) do
    Map.get(task, key) || Map.get(task, Atom.to_string(key))
  end

  defp present_map?(value) when is_map(value), do: map_size(value) > 0
  defp present_map?(_), do: false

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_), do: false

  defp present_list?(value) when is_list(value), do: value != []
  defp present_list?(_), do: false

  defp reviewer_result(%{reviewer_result: %{} = result}), do: result
  defp reviewer_result(%{"reviewer_result" => %{} = result}), do: result
  defp reviewer_result(_), do: nil

  defp structured_status_label("passed"), do: gettext("passed")
  defp structured_status_label("failed"), do: gettext("failed")
  defp structured_status_label("not_assessed"), do: gettext("not assessed")
  defp structured_status_label(_), do: nil

  defp structured_status_passed("passed"), do: true
  defp structured_status_passed("failed"), do: false
  defp structured_status_passed(_), do: nil

  @doc """
  Extracts the body of a markdown heading matching the given regex —
  everything between the matched `###`/`##` line and the next heading.
  Returns `nil` when the report is missing or the section is absent.
  """
  def report_section(%{review_report: report}, heading_regex)
      when is_binary(report) and report != "" do
    report
    |> String.split(~r/\r?\n/)
    |> Enum.split_while(fn line -> not heading_match?(line, heading_regex) end)
    |> extract_section_body()
  end

  def report_section(%{"review_report" => report}, heading_regex)
      when is_binary(report) and report != "" do
    report_section(%{review_report: report}, heading_regex)
  end

  def report_section(_, _), do: nil

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

  defp all_present_heading?(%{"review_report" => report}, regex) do
    all_present_heading?(%{review_report: report}, regex)
  end

  defp all_present_heading?(_, _), do: false

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
      Regex.match?(~r/(none\s+violated|no\s+violations|all\s+(honored|honoured))/i, body) ->
        false

      Regex.match?(~r/(violated|violations?)/i, body) ->
        true

      true ->
        false
    end
  end

  defp pitfalls_violated?(_), do: false

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

  defp section_passed(task, :testing_strategy), do: testing_strategy_passed(task)
  defp section_passed(task, :patterns), do: patterns_passed(task)
  defp section_passed(task, :pitfalls), do: pitfalls_passed(task)
  defp section_passed(task, :security_considerations), do: security_considerations_passed(task)

  defp section_value(task, :testing_strategy), do: testing_strategy_value(task)
  defp section_value(task, :patterns), do: patterns_value(task)
  defp section_value(task, :pitfalls), do: pitfalls_value(task)

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
      label: section_label(section),
      value: section_value(task, section),
      passed: section_passed(task, section),
      status: section_status_key(task, section),
      note: section_note(task, section),
      incomplete?: section_incomplete?(task, section),
      breakdown: section_breakdown(task, section)
    }
  end

  # The testing-strategy row expands into the task's own per-category strategy
  # entries; the other sections have no structured breakdown.
  defp section_breakdown(task, :testing_strategy), do: testing_strategy_breakdown(task)
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

  @doc """
  Reads the reviewer's one-line security rationale. Returns `nil` for
  absent/blank/non-string notes so the paragraph is omitted rather than
  rendering empty.
  """
  @spec security_considerations_note(map()) :: String.t() | nil
  def security_considerations_note(task),
    do: section_note(task, :security_considerations)
end
