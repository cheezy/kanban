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
end
