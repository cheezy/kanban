defmodule Kanban.Tasks.CompletionValidation.TaskConsistency do
  @moduledoc """
  Cross-checks a dispatched `reviewer_result` against the task it describes.

  Shape validation (`Kanban.Tasks.CompletionValidation`) confirms a review is
  internally well-formed; it cannot tell that the review is *consistent with its
  task* — that a section the task asked about actually got assessed. This module
  closes that gap with three task-aware rules:

    1. If the task supplied `security_considerations`, the report's
       `security_considerations` verdict must be a real assessment
       (`passed`/`failed`), never `not_assessed` or absent. This is the exact
       D60 defect — a task that listed security considerations came back
       "not assessed".
    2. If the task supplied a `testing_strategy`, the report's
       `testing_strategy` verdict must likewise be a real assessment.
    3. The report's `acceptance_criteria` entries must account for every
       acceptance-criterion line the task defined (compared by count of
       non-empty lines, never by exact text).

  When the task supplies no content for a field, that field's rule is skipped —
  the report is never forced to invent a verdict for something the task did not
  ask about. Only `dispatched: true` reviews are cross-checked; a skip-form
  review carries no verdicts and passes through untouched.

  Returns `{:ok, result}` or `{:error, [{field, message}, ...]}`, the same shape
  as the shape validator, so callers can merge failures uniformly.
  """

  use Gettext, backend: KanbanWeb.Gettext

  @real_verdicts ["passed", "failed"]

  @doc """
  Cross-checks a dispatched `reviewer_result` against `task`.

  `task` may be any map/struct exposing `:security_considerations`,
  `:testing_strategy`, and `:acceptance_criteria` (the `Kanban.Tasks.Task`
  struct). A non-dispatched (skip-form) review passes through as `{:ok, result}`.
  """
  def cross_check(%{"dispatched" => true} = result, task) do
    errors =
      []
      |> check_section(result, task, "security_considerations", :security_considerations)
      |> check_section(result, task, "testing_strategy", :testing_strategy)
      |> check_acceptance_criteria(result, task)

    case errors do
      [] -> {:ok, result}
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  def cross_check(result, _task), do: {:ok, result}

  @doc """
  W1866 — **grace-gated** self-consistency check on a dispatched
  `reviewer_result`'s optional `security_considerations.considerations[]`
  breakdown.

  When the breakdown is present and any entry is marked `partial` or
  `unmitigated`, the `security_considerations` section verdict must be `failed`
  — an outstanding or partial mitigation cannot coexist with a passing security
  verdict. When it is not, this returns a single `{:security_considerations, msg}`
  failure so the gate can record a structured warning (grace) and only reject in
  strict mode — unlike `cross_check/2`, whose failures always reject.

  Returns a bare list (`[]` when consistent / not applicable), matching the
  grace-gated shape `CompletionValidation.acceptance_criteria_count_failures/2`
  uses. The rule is self-consistency within the review, so no `task` argument is
  needed. Only a dispatched review carries the obligation; a skip-form review, an
  absent/nil breakdown, and a non-list `considerations` value all yield `[]` (the
  shape validator owns the non-list rejection). Known status strings are matched
  literally — never `String.to_atom`ed.
  """
  def considerations_status_consistency_failures(%{"dispatched" => true} = result) do
    case Map.get(result, "security_considerations") do
      %{"considerations" => considerations} = section when is_list(considerations) ->
        check_considerations_consistency(section, considerations)

      _ ->
        []
    end
  end

  def considerations_status_consistency_failures(_result), do: []

  defp check_considerations_consistency(section, considerations) do
    if Enum.any?(considerations, &partial_or_unmitigated?/1) and
         Map.get(section, "status") != "failed" do
      [{:security_considerations, considerations_status_message()}]
    else
      []
    end
  end

  defp partial_or_unmitigated?(%{"status" => status})
       when status in ["partial", "unmitigated"],
       do: true

  defp partial_or_unmitigated?(_), do: false

  # When the task supplied content for the section, the review's verdict for it
  # must be a real assessment, not "not_assessed"/absent.
  defp check_section(errors, result, task, result_key, task_field) do
    if supplied?(Map.get(task, task_field)) and
         section_status(result, result_key) not in @real_verdicts do
      [{task_field, unassessed_when_supplied_message(result_key)} | errors]
    else
      errors
    end
  end

  defp check_acceptance_criteria(errors, result, task) do
    expected = task |> Map.get(:acceptance_criteria) |> acceptance_line_count()

    if expected > 0 do
      supplied = result |> Map.get("acceptance_criteria") |> list_length()

      if supplied >= expected do
        errors
      else
        [{:acceptance_criteria, acceptance_shortfall_message(expected, supplied)} | errors]
      end
    else
      errors
    end
  end

  defp section_status(result, key) do
    case Map.get(result, key) do
      %{"status" => status} -> status
      _ -> nil
    end
  end

  # "Supplied" means the task author actually gave content for the field. nil,
  # "", [], an all-empty map, and a list/map whose values are all empty all count
  # as not supplied — so the matching rule is skipped.
  defp supplied?(nil), do: false
  defp supplied?(""), do: false
  defp supplied?([]), do: false
  defp supplied?(value) when is_binary(value), do: String.trim(value) != ""
  defp supplied?(value) when is_list(value), do: Enum.any?(value, &supplied?/1)

  defp supplied?(%{} = map),
    do: map_size(map) > 0 and map |> Map.values() |> Enum.any?(&supplied?/1)

  defp supplied?(_), do: true

  defp acceptance_line_count(value) when is_binary(value) do
    value
    |> String.split("\n")
    |> Enum.count(&(String.trim(&1) != ""))
  end

  defp acceptance_line_count(_), do: 0

  defp list_length(value) when is_list(value), do: length(value)
  defp list_length(_), do: 0

  defp unassessed_when_supplied_message(key) do
    gettext(
      "must be a real assessment: the task supplied %{field}, so the review must record a passed/failed verdict for it, not not_assessed or absent",
      field: key
    )
  end

  defp acceptance_shortfall_message(expected, supplied) do
    gettext(
      "is incomplete: the review checked %{supplied} of the task's %{expected} acceptance criteria; every acceptance criterion must be assessed",
      expected: expected,
      supplied: supplied
    )
  end

  defp considerations_status_message do
    gettext(
      "is inconsistent: the considerations breakdown marks an item partial or unmitigated, so the security_considerations verdict must be failed"
    )
  end
end
