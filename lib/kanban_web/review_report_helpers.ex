defmodule KanbanWeb.ReviewReportHelpers do
  @moduledoc """
  Regex-based extractors for the legacy markdown `review_report` field on a
  task. Centralises the parsing logic so both `KanbanWeb.ReviewLive` and the
  shared `KanbanWeb.ReviewReportPanel` component can derive the testing,
  patterns, and pitfalls verdict cells from the same source of truth.

  Every function is pure. Pass a map that may contain a `:review_report`
  string key (the LiveView struct) or a binary `"review_report"` key (raw
  task map). Functions return `nil` when the section is missing, so callers
  can render an em-dash default.
  """
  use Gettext, backend: KanbanWeb.Gettext

  @doc """
  Human-readable value for the testing-strategy verdict cell.

  Prefers the structured `reviewer_result["testing_strategy"]["status"]`
  when present; falls back to regex extraction from `review_report`.
  Returns a localized string or `nil` when no source has a value.
  """
  def testing_strategy_value(task) do
    case structured_section_status(task, "testing_strategy") do
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
    case structured_section_status(task, "testing_strategy") do
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
    case structured_section_status(task, "patterns") do
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
    case structured_section_status(task, "patterns") do
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
    case structured_section_status(task, "pitfalls") do
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
    case structured_section_status(task, "pitfalls") do
      nil ->
        case report_section(task, ~r/pitfalls/i) do
          nil -> nil
          body -> not pitfalls_violated?(body)
        end

      status ->
        structured_status_passed(status)
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
