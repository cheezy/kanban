defmodule KanbanWeb.ReviewReportHelpers.MarkdownReport do
  @moduledoc """
  Parsing for the legacy markdown `review_report` field on a task.

  Split out of `KanbanWeb.ReviewReportHelpers` (W2004), which had grown past
  the module-size guidance in `AGENTS.md`. Everything here operates on a
  `review_report` binary and nothing else — it reads no structured field and
  calls nothing in the parent module.

  `all_present_heading?/2`, `count_list_items/1` and `pitfalls_violated?/1`
  were private before the split and are public now only because the parent's
  regex fallbacks call them across the new module boundary. They are internal
  API: prefer the parent's `testing_strategy_value/1` and friends.

  Every function is pure. Pass a map that may carry a `:review_report` atom
  key (the LiveView struct) or a `"review_report"` binary key (a raw task
  map). Functions return `nil` when the section is missing.
  """

  @doc """
  Extracts the body of a markdown heading matching the given regex —
  everything between the matched `###`/`##` line and the next heading.
  Returns `nil` when the report is missing or the section is absent.
  """
  @spec report_section(map(), Regex.t()) :: String.t() | nil
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

  # True when the report contains a heading matching `regex` that also declares
  # the section fully covered — an "all present"/"all covered"/"all met" marker.
  #
  # Public only because the parent module's legacy regex fallbacks call it
  # across the module boundary; it was private before the W2004 split. Marked
  # @doc false so the documented API stays as narrow as it was pre-split.
  @doc false
  @spec all_present_heading?(map(), Regex.t()) :: boolean()
  def all_present_heading?(%{review_report: report}, regex)
      when is_binary(report) and report != "" do
    report
    |> String.split(~r/\r?\n/)
    |> Enum.any?(fn line ->
      trimmed = String.trim(line)

      String.starts_with?(trimmed, "#") and Regex.match?(regex, trimmed) and
        Regex.match?(~r/all\s+(present|covered|met)/i, trimmed)
    end)
  end

  def all_present_heading?(%{"review_report" => report}, regex) do
    all_present_heading?(%{review_report: report}, regex)
  end

  def all_present_heading?(_, _), do: false

  # Counts markdown list items — `-`, `*` or `1.` bullets — in a section body.
  # Public for the same boundary reason as all_present_heading?/2.
  @doc false
  @spec count_list_items(term()) :: non_neg_integer()
  def count_list_items(body) when is_binary(body) do
    body
    |> String.split(~r/\r?\n/)
    |> Enum.count(fn line ->
      trimmed = String.trim_leading(line)

      String.starts_with?(trimmed, "- ") or String.starts_with?(trimmed, "* ") or
        Regex.match?(~r/^\d+\.\s+/, trimmed)
    end)
  end

  def count_list_items(_), do: 0

  # True when a pitfalls section body reads as reporting violations. An explicit
  # "none violated"/"no violations"/"all honored" marker wins over a bare
  # mention of the word, so the negated phrasing is checked first. Public for
  # the same boundary reason as the two helpers above.
  @doc false
  @spec pitfalls_violated?(term()) :: boolean()
  def pitfalls_violated?(body) when is_binary(body) do
    cond do
      Regex.match?(~r/(none\s+violated|no\s+violations|all\s+(honored|honoured))/i, body) ->
        false

      Regex.match?(~r/(violated|violations?)/i, body) ->
        true

      true ->
        false
    end
  end

  def pitfalls_violated?(_), do: false
end
