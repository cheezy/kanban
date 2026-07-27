defmodule Kanban.Tasks.CompletionValidation.BehaviourTestMatrix do
  @moduledoc """
  Validates the OPTIONAL `behaviour_test_matrix` verdict on a reviewer result —
  the reviewer's echo of the task's behaviour/test matrix (W1920).

  One responsibility: given a supplied verdict, check the shape of what was
  actually sent. It never demands a verdict (the matrix is never a required
  review section) and never demands a complete one — a map with no `status`
  and no `rows` passes untouched. What it does check is that a supplied
  `status` is a recognized section verdict, that `rows` is a list, and that
  each supplied row carries the strings a persisted row would need.

  ## Why the row rules are exactly this strict and no stricter

  These failures are NOT soft. `AgentWorkflow.validate_reviewer_result_payload/2`
  folds every `{field, message}` into the `/complete` changeset unconditionally
  (W398), so anything flagged here is a hard completion failure in every mode.
  The required row keys therefore mirror
  `Kanban.Schemas.Task.BehaviourTestRow.changeset/2` exactly rather than
  demanding every column: a waived row (`status: "not_applicable"`) carries no
  `test_name`, and demanding more of the reviewer's report than the schema
  demands of the persisted row would reject a faithful echo of a valid matrix.

  ## Ecto-free by construction

  The status enum is a literal atom list here, not a call into the embedded
  schema, because the whole `CompletionValidation` family is deliberately
  Ecto-free. `completion_validation_test.exs` keeps the two lists honest with a
  drift guard rather than a dependency.

  Row errors use static atom keys with the index embedded in the message, so no
  runtime atoms are created per index — reviewer-supplied rows are untrusted
  data and are never converted to atoms.
  """

  alias Kanban.Tasks.CompletionValidation.Fields

  # W1920: the per-row status enum for the OPTIONAL nested
  # `behaviour_test_matrix.rows[]` breakdown. Mirrors
  # `Kanban.Schemas.Task.BehaviourTestRow.statuses/0`, kept here as a literal
  # atom list because this module is deliberately Ecto-free and must not depend
  # on an embedded schema; `completion_validation_test.exs` asserts the two
  # lists stay in agreement.
  @behaviour_test_status_enum [:planned, :passing, :failing, :not_applicable]

  # Row keys that must be non-empty strings when a row is supplied, and keys that
  # must be strings only when supplied. Deliberately mirrors
  # `Kanban.Schemas.Task.BehaviourTestRow.changeset/2`'s
  # `validate_required([:category, :behaviour, :status])`: a waived row
  # (`status: "not_applicable"`) legitimately carries no `test_name` — it carries
  # `na_reason` instead — and `type` is never required there. Demanding more of
  # the reviewer's report than the schema demands of the persisted row would
  # reject a faithful echo of a valid matrix. Both lists are fixed and
  # compile-time; row keys are never derived from reviewer input.
  @behaviour_test_row_required_keys ~w(category behaviour)
  @behaviour_test_row_optional_keys ~w(test_name type)

  @doc """
  The allowed `behaviour_test_matrix.rows[].status` values, as atoms (W1920).

  Exposed — and re-exported by `Kanban.Tasks.CompletionValidation` — as the
  assertion surface for the drift guard that keeps this list in lockstep with
  `Kanban.Schemas.Task.BehaviourTestRow.statuses/0`.
  """
  def statuses, do: @behaviour_test_status_enum

  @doc """
  Folds any `behaviour_test_matrix` failures into `errors`.

  Takes the error accumulator FIRST, prepends new failures to it, and returns
  the still-unreversed list — the caller reverses once at the end. An absent,
  nil, or partial verdict adds nothing.
  """
  # W1920: OPTIONAL `behaviour_test_matrix` verdict — the reviewer's echo of the
  # task's behaviour/test matrix. It is never listed in @required_review_sections,
  # so an absent verdict carries no obligation. A *partial* verdict is equally
  # free: a map with no `status` and no `rows` (or explicit nils) passes
  # untouched, matching the `security_considerations.considerations[]` precedent.
  #
  # Emitting no error is the only way to let a verdict through: these failures
  # are NOT soft. `AgentWorkflow.validate_reviewer_result_payload/2` folds every
  # `{field, message}` into the `/complete` changeset unconditionally (W398), so
  # anything flagged here is a hard completion failure in every mode — which is
  # why the required row keys mirror `BehaviourTestRow.changeset/2` exactly
  # rather than demanding every column.
  #
  # What IS checked is the shape of what was actually supplied: a present
  # `status` must be a recognized section verdict, `rows` must be a list, and
  # each supplied row must be a map carrying non-empty strings for
  # @behaviour_test_row_required_keys, strings for any supplied
  # @behaviour_test_row_optional_keys, and a `status` in
  # @behaviour_test_status_enum. Row errors use static atom keys with the index
  # embedded in the message, matching `check_consideration_entry/3`, so no
  # runtime atoms are created per index — reviewer-supplied rows are untrusted
  # data and are never converted to atoms.
  def check(errors, %{"behaviour_test_matrix" => verdict})
      when is_map(verdict) do
    errors
    |> check_matrix_status(verdict)
    |> Fields.check_section_notes(verdict, "behaviour_test_matrix")
    |> check_matrix_rows(verdict)
  end

  # An explicit nil verdict is treated exactly like an absent key.
  def check(errors, %{"behaviour_test_matrix" => nil}), do: errors

  def check(errors, %{"behaviour_test_matrix" => _}),
    do: [{:behaviour_test_matrix_entry, "behaviour_test_matrix must be a map"} | errors]

  def check(errors, _result), do: errors

  # Absent or nil `status` is a partial verdict, not an error — only a supplied
  # value is enum-checked.
  defp check_matrix_status(errors, %{"status" => status} = verdict) when not is_nil(status) do
    Fields.check_section_status(
      errors,
      verdict,
      :behaviour_test_matrix_status,
      "behaviour_test_matrix"
    )
  end

  defp check_matrix_status(errors, _verdict), do: errors

  defp check_matrix_rows(errors, %{"rows" => rows}) when is_list(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {row, idx}, acc -> check_behaviour_test_row(acc, row, idx) end)
  end

  # Absent or nil `rows` is a partial verdict, not an error.
  defp check_matrix_rows(errors, %{"rows" => nil}), do: errors

  defp check_matrix_rows(errors, %{"rows" => _}),
    do: [{:behaviour_test_matrix_rows, "behaviour_test_matrix.rows must be a list"} | errors]

  defp check_matrix_rows(errors, _verdict), do: errors

  defp check_behaviour_test_row(errors, row, idx) when is_map(row) do
    errors
    |> check_behaviour_test_row_fields(row, idx)
    |> Fields.check_enum(
      row,
      "status",
      @behaviour_test_status_enum,
      :behaviour_test_row_status,
      behaviour_test_row_prefix(idx)
    )
  end

  defp check_behaviour_test_row(errors, _row, idx),
    do: [
      {:behaviour_test_row_entry, "#{behaviour_test_row_prefix(idx)} must be a map"} | errors
    ]

  defp check_behaviour_test_row_fields(errors, row, idx) do
    errors
    |> check_required_row_strings(row, idx)
    |> check_optional_row_strings(row, idx)
  end

  defp check_required_row_strings(errors, row, idx) do
    Enum.reduce(@behaviour_test_row_required_keys, errors, fn key, acc ->
      if present_string?(Map.get(row, key)) do
        acc
      else
        [{:behaviour_test_row_field, behaviour_test_row_field_message(idx, key)} | acc]
      end
    end)
  end

  # Absent or nil is a partial row, not a malformed one — only a supplied value
  # is type-checked.
  defp check_optional_row_strings(errors, row, idx) do
    Enum.reduce(@behaviour_test_row_optional_keys, errors, fn key, acc ->
      check_optional_row_string(acc, Map.get(row, key), key, idx)
    end)
  end

  defp check_optional_row_string(errors, nil, _key, _idx), do: errors
  defp check_optional_row_string(errors, value, _key, _idx) when is_binary(value), do: errors

  defp check_optional_row_string(errors, _value, key, idx),
    do: [{:behaviour_test_row_field, optional_row_field_message(idx, key)} | errors]

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  # Both message builders interpolate only `idx` (an integer) and `key` (a
  # compile-time literal), never a row value — these strings are echoed verbatim
  # in the 422 body and in the gate's warning log.
  defp behaviour_test_row_field_message(idx, key),
    do: "#{behaviour_test_row_prefix(idx)} must have a non-empty string \"#{key}\""

  defp optional_row_field_message(idx, key),
    do: "#{behaviour_test_row_prefix(idx)} \"#{key}\" must be a string when supplied"

  defp behaviour_test_row_prefix(idx), do: "behaviour_test_matrix.rows[#{idx}]"
end
