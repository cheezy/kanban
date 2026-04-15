defmodule Kanban.Tasks.CompletionValidation do
  @moduledoc """
  Validates `explorer_result` and `reviewer_result` payloads submitted to
  `PATCH /api/tasks/:id/complete`.

  Pure, Ecto-free validator. Accepts string-keyed maps (the shape produced
  by JSON decoding) and returns either `{:ok, result}` or
  `{:error, [{field, message}, ...]}` with every failing field listed.

  The `skip_reasons/0` enum is the exhaustive list of allowed `"reason"`
  values when a step was not dispatched. Callers that self-report — platforms
  without subagent support, or small tasks that legitimately skip
  exploration — must pick a reason from this list. Free-form reasons are
  rejected, and summaries that do not clear the minimum non-whitespace
  length are also rejected. Friction is intentional: it is the cost of a
  hard gate that accepts evidence from every platform without letting
  anyone paper over a skipped step with a one-word excuse.
  """

  @skip_reasons [
    :no_subagent_support,
    :small_task_0_1_key_files,
    :trivial_change_docs_only,
    :self_reported_exploration,
    :self_reported_review
  ]

  @min_summary_length 40

  @doc """
  The exhaustive list of allowed skip-reason atoms.

  Exposed as the single source of truth for API layers, tests, and
  documentation — the same list must appear byte-identical in every plugin
  skill so that server-side aggregation groups identical reasons.
  """
  def skip_reasons, do: @skip_reasons

  @doc """
  Validates an `explorer_result` payload.

  Returns `{:ok, result}` when every rule passes, or
  `{:error, [{field, message}, ...]}` listing every failing field.

  When `"dispatched"` is `true`, requires `"summary"` (≥ #{@min_summary_length}
  non-whitespace characters) and `"duration_ms"` (non-negative integer).
  When `"dispatched"` is `false`, requires `"reason"` (one of
  `skip_reasons/0`) and `"summary"` (≥ #{@min_summary_length}
  non-whitespace characters).
  """
  def validate_explorer_result(result), do: validate(result, :explorer)

  @doc """
  Validates a `reviewer_result` payload.

  Same rules as `validate_explorer_result/1`, plus: when `"dispatched"` is
  `true`, also requires `"acceptance_criteria_checked"` and `"issues_found"`
  as non-negative integers.
  """
  def validate_reviewer_result(result), do: validate(result, :reviewer)

  defp validate(nil, _role), do: {:error, [{:result, "can't be blank"}]}

  defp validate(result, _role) when not is_map(result),
    do: {:error, [{:result, "must be a map"}]}

  defp validate(result, role) do
    errors =
      []
      |> check_dispatched(result)
      |> check_summary(result)
      |> check_by_dispatched(result, role)

    case errors do
      [] -> {:ok, result}
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  defp check_dispatched(errors, %{"dispatched" => d}) when is_boolean(d), do: errors
  defp check_dispatched(errors, _), do: [{:dispatched, "must be a boolean"} | errors]

  defp check_summary(errors, %{"summary" => s}) when is_binary(s) do
    if non_whitespace_length(s) >= @min_summary_length do
      errors
    else
      [{:summary, summary_length_message()} | errors]
    end
  end

  defp check_summary(errors, _), do: [{:summary, summary_length_message()} | errors]

  defp check_by_dispatched(errors, %{"dispatched" => true} = result, :reviewer) do
    errors
    |> check_duration_ms(result)
    |> check_nn_int(result, "acceptance_criteria_checked", :acceptance_criteria_checked)
    |> check_nn_int(result, "issues_found", :issues_found)
  end

  defp check_by_dispatched(errors, %{"dispatched" => true} = result, :explorer) do
    check_duration_ms(errors, result)
  end

  defp check_by_dispatched(errors, %{"dispatched" => false} = result, _role) do
    check_reason(errors, result)
  end

  defp check_by_dispatched(errors, _result, _role), do: errors

  defp check_duration_ms(errors, %{"duration_ms" => d}) when is_integer(d) and d >= 0, do: errors

  defp check_duration_ms(errors, _),
    do: [{:duration_ms, "must be a non-negative integer"} | errors]

  defp check_reason(errors, %{"reason" => reason}) when is_binary(reason) do
    case string_to_skip_atom(reason) do
      {:ok, _atom} -> errors
      :error -> [{:reason, invalid_reason_message()} | errors]
    end
  end

  defp check_reason(errors, %{"reason" => reason}) when is_atom(reason) and not is_nil(reason) do
    if reason in @skip_reasons do
      errors
    else
      [{:reason, invalid_reason_message()} | errors]
    end
  end

  defp check_reason(errors, _), do: [{:reason, invalid_reason_message()} | errors]

  defp check_nn_int(errors, result, key, field) do
    case Map.get(result, key) do
      v when is_integer(v) and v >= 0 -> errors
      _ -> [{field, "must be a non-negative integer"} | errors]
    end
  end

  defp non_whitespace_length(string) do
    string
    |> String.replace(~r/\s/u, "")
    |> String.length()
  end

  defp summary_length_message,
    do: "must be a string of at least #{@min_summary_length} non-whitespace characters"

  defp invalid_reason_message do
    allowed = @skip_reasons |> Enum.map_join(", ", &Atom.to_string/1)
    "must be one of: #{allowed}"
  end

  defp string_to_skip_atom(reason) do
    atom = String.to_existing_atom(reason)

    if atom in @skip_reasons do
      {:ok, atom}
    else
      :error
    end
  rescue
    ArgumentError -> :error
  end
end
