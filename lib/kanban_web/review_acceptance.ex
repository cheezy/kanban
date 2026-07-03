defmodule KanbanWeb.ReviewAcceptance do
  @moduledoc """
  Pure derivation helpers for the Acceptance-criteria cell and checklist on the
  Review queue.

  Extracted from `KanbanWeb.ReviewLive` (W1441) so the derivation logic is
  testable in isolation. Covers the header value (checked/total counts with
  clamping and issue counts), the pass/fail tone, per-criterion checked/failed
  maps, and the legacy `review_report` "Acceptance criteria status" regex parser.

  Every function is pure. Unlike `KanbanWeb.ReviewReportHelpers`, these functions
  read `task.acceptance_criteria` via struct/atom-field access (not
  `Map.get/2`), so they expect a task struct (or an atom-keyed map that carries
  the field) rather than a string-keyed map.
  """

  use Gettext, backend: KanbanWeb.Gettext

  # Regexes used by the `acceptance_status_map/1` parser. Module attributes are
  # evaluated at their point of definition during compilation, so they must be
  # declared above the function that references them.
  @status_heading_regex ~r/acceptance\s+criteria\s+status/i
  @status_line_regex ~r/^(\d+)\.\s*(.+?)\s*[—–-]+\s*(Not\s+Met|Met)\.?\s*$/i

  @doc """
  Header value for the Acceptance cell, e.g. `"4/5"`, `"3/5 · 2 issues"`, or the
  bare total when the reviewer did not run. Returns `nil` when the task has no
  acceptance criteria.
  """
  @spec acceptance_value(map()) :: String.t() | nil
  def acceptance_value(task) do
    total = task.acceptance_criteria |> parse_lines() |> length()
    format_acceptance_value(task, total)
  end

  @doc """
  True when the stored review counts drifted from the task's own
  acceptance-criteria count, so the header shows a data-inconsistency indicator
  next to the (clamped) value (W1102). Mirrors the server's grace-gated check:
  the legacy `acceptance_criteria_checked` integer OR the structured
  `acceptance_criteria` array length disagreeing with the task's line count.
  """
  @spec acceptance_inconsistent?(map()) :: boolean()
  def acceptance_inconsistent?(task) do
    total = task.acceptance_criteria |> parse_lines() |> length()
    total > 0 and reviewer_dispatched?(task) and acceptance_count_drift?(task, total)
  end

  @doc """
  Tone for the Acceptance cell: `true` → passed, `false` → failed, `nil` →
  neutral. Driven by the structured `reviewer_result.status` first, then by
  structured `acceptance_criteria`. It never flips to failed purely from a
  legacy `issues_found` count, so a legacy/thin reviewer_result stays neutral
  and cannot contradict the (neutral) status pill (D56). Mirrors
  `KanbanWeb.ReviewQueueItem.acceptance_passed?/1` so the two acceptance
  surfaces never disagree.
  """
  @spec acceptance_passed(map()) :: boolean() | nil
  def acceptance_passed(%{reviewer_result: %{"status" => "approved"}}), do: true
  def acceptance_passed(%{reviewer_result: %{"status" => "changes_requested"}}), do: false

  def acceptance_passed(%{reviewer_result: %{} = result}) do
    case Map.get(result, "acceptance_criteria") do
      list when is_list(list) and list != [] ->
        not Enum.any?(list, &match?(%{"status" => "not_met"}, &1))

      _ ->
        nil
    end
  end

  def acceptance_passed(_), do: nil

  @doc """
  Maps each criterion row index to `true` when checked (`:met`). When the
  `review_report` contains an "Acceptance criteria status" section, parses it to
  derive per-row state. Falls back to "all rows checked" when the reviewer ran
  and the bulk count matches the total — i.e. the reviewer covered everything
  but didn't itemise.
  """
  @spec acceptance_checked(map()) :: %{optional(non_neg_integer()) => true}
  def acceptance_checked(task) do
    statuses = acceptance_status_map(task)

    if map_size(statuses) > 0 do
      statuses_to_bool_map(statuses, :met)
    else
      fallback_acceptance_checked(task)
    end
  end

  @doc """
  Maps each criterion row index to `true` when the parsed `review_report`
  marked it `:not_met`. Empty when there is no parseable status section.
  """
  @spec acceptance_failed(map()) :: %{optional(non_neg_integer()) => true}
  def acceptance_failed(task) do
    task
    |> acceptance_status_map()
    |> statuses_to_bool_map(:not_met)
  end

  @doc """
  Returns the structured `reviewer_result.acceptance_criteria` list when the
  reviewer subagent supplied one, otherwise `[]`. The checklist consumes this
  list directly to render per-criterion verdict + evidence, bypassing the
  raw-string parsing path.
  """
  @spec structured_acceptance(map()) :: list()
  def structured_acceptance(%{reviewer_result: %{"acceptance_criteria" => list}})
      when is_list(list),
      do: list

  def structured_acceptance(_), do: []

  defp acceptance_count_drift?(task, total) do
    legacy_drift? = checked_count(task, total) != total
    structured_len = task |> structured_acceptance() |> length()
    structured_drift? = structured_len > 0 and structured_len != total

    legacy_drift? or structured_drift?
  end

  defp format_acceptance_value(_task, 0), do: nil

  defp format_acceptance_value(task, total) do
    if reviewer_dispatched?(task) do
      reviewer_acceptance_value(task, total)
    else
      Integer.to_string(total)
    end
  end

  # Reviewer ran — pick between the clean-pass and issues-found rendering. The
  # checked count is clamped to `total` so the header can never render an
  # impossible value like "6/5" when the stored review record drifted from the
  # task (W1102). The honest drift signal is surfaced separately by
  # `acceptance_inconsistent?/1`.
  defp reviewer_acceptance_value(task, total) do
    checked = task |> checked_count(total) |> min(total)
    n_issues = displayable_issues_count(task)

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

  defp reviewer_dispatched?(%{reviewer_result: %{"dispatched" => true}}), do: true
  defp reviewer_dispatched?(_), do: false

  defp issues_found(%{reviewer_result: %{"issues_found" => n}}) when is_integer(n), do: n
  defp issues_found(_), do: nil

  # Prefer the count of displayable structured issues so the header never
  # advertises "N issues" with no corresponding issue list. Falls back to the
  # legacy scalar issues_found only when no structured issues[] is present (D59).
  defp displayable_issues_count(%{reviewer_result: %{"issues" => issues}}) when is_list(issues),
    do: length(issues)

  defp displayable_issues_count(task), do: issues_found(task) || 0

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
end
