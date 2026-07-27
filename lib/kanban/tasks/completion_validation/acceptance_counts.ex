defmodule Kanban.Tasks.CompletionValidation.AcceptanceCounts do
  @moduledoc """
  The **grace-gated** acceptance-criteria count agreement between a dispatched
  `reviewer_result` and the task it describes.

  One responsibility, and it is deliberately not the same one as
  `Kanban.Tasks.CompletionValidation.ReviewContract`: these failures follow the
  `:strict_completion_validation` flag rather than rejecting unconditionally.
  The gate warns in grace mode and returns a 422 only in strict mode, matching
  the documented rollout.

  It compares two independent numbers against the task's criterion-line count —
  the review's structured `acceptance_criteria` array length and its legacy
  `acceptance_criteria_checked` integer — each only when present and
  well-typed, and reports any inequality.

  ## Why this exists next to TaskConsistency

  `TaskConsistency.cross_check/2` flags only a *shortfall*: a review that
  checked fewer criteria than the task lists. An over-count slips through it.
  That was the W1099 "6/5" gap — a re-review that re-enumerated the criteria in
  its own words persisted a count larger than the task's. Here any inequality
  in either direction is flagged.

  Malformed shapes (a non-list array, a non-integer count) are left to the
  shape validator and never raise here — the field simply contributes no count
  failure.
  """

  use Gettext, backend: KanbanWeb.Gettext

  @doc """
  Returns **grace-gated** acceptance-criteria count failures for a dispatched
  `reviewer_result`, measured against the `task` it describes.

  Unlike `Kanban.Tasks.CompletionValidation.ReviewContract.failures/2` (which rejects unconditionally), these
  failures follow the `:strict_completion_validation` flag: the gate warns in
  grace mode and rejects with a 422 only in strict mode, matching the documented
  rollout. The check compares the review's structured `acceptance_criteria` array
  length AND its legacy `acceptance_criteria_checked` integer — each only when
  present and well-typed — to the task's criterion-line count. A disagreement in
  either is reported as `{field, message}`.

  This closes the W1099 "6/5" gap that `TaskConsistency.cross_check/2` misses:
  that rule only flags a *shortfall* (the review checked fewer criteria than the
  task lists), so an over-count slips through. Here any inequality is flagged.

  Returns `[]` (consistent / not applicable) when the task defines no acceptance
  criteria, when the review was not dispatched, or when `task` is nil. Malformed
  shapes (a non-list array, a non-integer count) are left to the shape validator
  and never raise here — the field simply contributes no count failure.
  """
  def failures(result, task)

  def failures(%{"dispatched" => true} = result, %{} = task) do
    expected = task |> Map.get(:acceptance_criteria) |> acceptance_line_count()

    if expected > 0 do
      []
      |> check_structured_criteria_count(result, expected)
      |> check_legacy_checked_count(result, expected)
      |> Enum.reverse()
    else
      []
    end
  end

  def failures(_result, _task), do: []

  defp check_structured_criteria_count(errors, %{"acceptance_criteria" => list}, expected)
       when is_list(list) do
    supplied = length(list)

    if supplied == expected do
      errors
    else
      [{:acceptance_criteria, acceptance_count_mismatch_message(expected, supplied)} | errors]
    end
  end

  defp check_structured_criteria_count(errors, _result, _expected), do: errors

  defp check_legacy_checked_count(errors, %{"acceptance_criteria_checked" => checked}, expected)
       when is_integer(checked) do
    if checked == expected do
      errors
    else
      [
        {:acceptance_criteria_checked, acceptance_checked_mismatch_message(expected, checked)}
        | errors
      ]
    end
  end

  defp check_legacy_checked_count(errors, _result, _expected), do: errors

  # Counts non-blank acceptance-criterion lines, matching the TaskConsistency and
  # ReviewLive parse semantics so the three count consistently.
  defp acceptance_line_count(value) when is_binary(value) do
    value
    |> String.split("\n")
    |> Enum.count(&(String.trim(&1) != ""))
  end

  defp acceptance_line_count(_), do: 0

  defp acceptance_count_mismatch_message(expected, supplied) do
    gettext(
      "is inconsistent with the task: the review lists %{supplied} acceptance-criteria entries but the task defines %{expected}; the counts must match",
      expected: expected,
      supplied: supplied
    )
  end

  defp acceptance_checked_mismatch_message(expected, checked) do
    gettext(
      "is inconsistent with the task: the review reports %{checked} acceptance criteria checked but the task defines %{expected}; the counts must match",
      expected: expected,
      checked: checked
    )
  end
end
