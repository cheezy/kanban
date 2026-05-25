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

  @severity_enum [:critical, :important, :minor]
  @category_enum [:acceptance_criteria, :pitfall, :pattern, :testing, :code_quality]
  @status_enum [:met, :not_met]
  @section_status_enum [:passed, :failed, :not_assessed]

  # Permissive semver: MAJOR.MINOR with optional .PATCH, pre-release, and
  # build metadata. Accepts "1.0", "1.2.3", "2.0.0-beta.1", "1.0+build.7".
  @semver_regex ~r/^\d+\.\d+(\.\d+)?(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$/

  @min_summary_length 40

  @max_diff_lines 500

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

  @doc """
  Validates the optional `changed_files` array on the completion payload.

  Returns `{:ok, value}` when valid (including `nil` for legacy payloads
  that omit the field entirely and `[]` for empty arrays), or
  `{:error, [{field, message}, ...]}` listing every failing entry.

  Each entry must be a map with a non-empty string `"path"`. The `"diff"`
  field is optional; when present it must be a string of at most
  #{@max_diff_lines} lines. The line cap is a defensive backstop — plugins
  are expected to truncate before sending, per `docs/diff-contract.md`.
  """
  def validate_changed_files(nil),
    do: {:error, [{:changed_files, "must be present (send [] to clear)"}]}

  def validate_changed_files(value) when is_list(value) do
    errors =
      value
      |> Enum.with_index()
      |> Enum.reduce([], fn {entry, idx}, acc -> check_changed_file_entry(acc, entry, idx) end)

    case errors do
      [] -> {:ok, value}
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  def validate_changed_files(_value), do: {:error, [{:changed_files, "must be a list"}]}

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
    |> check_issues(result)
    |> check_acceptance_criteria(result)
    |> check_section_verdict(
      result,
      "testing_strategy",
      :testing_strategy_status,
      :testing_strategy_entry
    )
    |> check_section_verdict(result, "patterns", :patterns_status, :patterns_entry)
    |> check_section_verdict(result, "pitfalls", :pitfalls_status, :pitfalls_entry)
    |> check_schema_version(result)
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

  # Optional structured `issues` array — when present, each entry must be a
  # map with a recognized `severity` and `category`. Absent or empty list is
  # accepted; a non-list value at the key is rejected. Entry-level errors
  # use static atom keys (`:issue_entry`, `:issue_severity`, `:issue_category`)
  # with the array position embedded in the message — this avoids creating
  # runtime atoms per index.
  defp check_issues(errors, %{"issues" => issues}) when is_list(issues) do
    issues
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {entry, idx}, acc -> check_issue_entry(acc, entry, idx) end)
  end

  defp check_issues(errors, %{"issues" => _}),
    do: [{:issues, "must be a list"} | errors]

  defp check_issues(errors, _), do: errors

  defp check_issue_entry(errors, entry, idx) when is_map(entry) do
    errors
    |> check_enum(entry, "severity", @severity_enum, :issue_severity, "issues[#{idx}]")
    |> check_enum(entry, "category", @category_enum, :issue_category, "issues[#{idx}]")
  end

  defp check_issue_entry(errors, _entry, idx),
    do: [{:issue_entry, "issues[#{idx}] must be a map"} | errors]

  # Optional structured `acceptance_criteria` array — when present, each
  # entry must be a map with a recognized `status` (met / not_met).
  defp check_acceptance_criteria(errors, %{"acceptance_criteria" => criteria})
       when is_list(criteria) do
    criteria
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {entry, idx}, acc -> check_criterion_entry(acc, entry, idx) end)
  end

  defp check_acceptance_criteria(errors, %{"acceptance_criteria" => _}),
    do: [{:acceptance_criteria, "must be a list"} | errors]

  defp check_acceptance_criteria(errors, _), do: errors

  defp check_criterion_entry(errors, entry, idx) when is_map(entry) do
    check_enum(
      errors,
      entry,
      "status",
      @status_enum,
      :criterion_status,
      "acceptance_criteria[#{idx}]"
    )
  end

  defp check_criterion_entry(errors, _entry, idx),
    do: [{:criterion_entry, "acceptance_criteria[#{idx}] must be a map"} | errors]

  # Optional section verdict (testing_strategy / patterns / pitfalls). When
  # present, must be a map with a recognized `status` and an optional
  # `notes` string. Absence is accepted; non-map values are rejected.
  defp check_section_verdict(errors, result, key, status_field, entry_field) do
    case Map.get(result, key) do
      nil ->
        errors

      verdict when is_map(verdict) ->
        errors
        |> check_enum(verdict, "status", @section_status_enum, status_field, key)
        |> check_section_notes(verdict, key)

      _ ->
        [{entry_field, "#{key} must be a map"} | errors]
    end
  end

  defp check_section_notes(errors, verdict, key) do
    case Map.get(verdict, "notes") do
      nil -> errors
      notes when is_binary(notes) -> errors
      _ -> [{:notes, "#{key}.notes must be a string"} | errors]
    end
  end

  # Optional `schema_version` — permissive semver shape, gates nothing on
  # specific version values. Tolerates absence entirely.
  defp check_schema_version(errors, %{"schema_version" => v}) when is_binary(v) do
    if Regex.match?(@semver_regex, v) do
      errors
    else
      [{:schema_version, "must be a semver-shaped string (e.g., \"1.0\", \"1.2.3\")"} | errors]
    end
  end

  defp check_schema_version(errors, %{"schema_version" => _}),
    do: [{:schema_version, "must be a semver-shaped string"} | errors]

  defp check_schema_version(errors, _), do: errors

  # Validates that `map[key]` is present and decodes to a member of `allowed`.
  # Mirrors the binary-or-atom acceptance pattern used by `check_reason/2`.
  # `prefix` is the entry locator (e.g., `"issues[0]"`) used in messages.
  defp check_enum(errors, map, key, allowed, field, prefix) do
    case decode_enum_field(Map.get(map, key), allowed) do
      :ok -> errors
      :missing -> [{field, "#{prefix} is missing #{key}"} | errors]
      :invalid -> [{field, "#{prefix} #{key} #{enum_message(allowed)}"} | errors]
    end
  end

  defp decode_enum_field(nil, _allowed), do: :missing

  defp decode_enum_field(value, allowed) when is_binary(value) do
    atom = String.to_existing_atom(value)
    if atom in allowed, do: :ok, else: :invalid
  rescue
    ArgumentError -> :invalid
  end

  defp decode_enum_field(value, allowed) when is_atom(value) do
    if value in allowed, do: :ok, else: :invalid
  end

  defp decode_enum_field(_value, _allowed), do: :invalid

  defp enum_message(allowed),
    do: "must be one of: " <> Enum.map_join(allowed, ", ", &Atom.to_string/1)

  # Per-entry validator for `changed_files`. Uses the same static-atom +
  # index-in-message pattern as `check_issue_entry/3` so we do not create
  # runtime atoms per array index.
  defp check_changed_file_entry(errors, entry, idx) when is_map(entry) do
    errors
    |> check_changed_file_path(entry, idx)
    |> check_changed_file_diff(entry, idx)
  end

  defp check_changed_file_entry(errors, _entry, idx),
    do: [{:changed_file_entry, "changed_files[#{idx}] must be a map"} | errors]

  defp check_changed_file_path(errors, entry, idx) do
    case Map.get(entry, "path") do
      path when is_binary(path) and byte_size(path) > 0 ->
        errors

      _ ->
        [
          {:changed_file_path, "changed_files[#{idx}] must have a non-empty string \"path\""}
          | errors
        ]
    end
  end

  defp check_changed_file_diff(errors, entry, idx) do
    case Map.get(entry, "diff") do
      nil ->
        errors

      diff when is_binary(diff) ->
        if diff_line_count(diff) > @max_diff_lines do
          [
            {:changed_file_diff,
             "changed_files[#{idx}].diff exceeds the #{@max_diff_lines}-line cap"}
            | errors
          ]
        else
          errors
        end

      _ ->
        [{:changed_file_diff, "changed_files[#{idx}].diff must be a string"} | errors]
    end
  end

  # Counts logical lines in a diff. A trailing newline is treated as a
  # line terminator, not a separator — so a 500-line patch with or
  # without a trailing newline reports 500 lines.
  defp diff_line_count(diff) do
    diff
    |> String.trim_trailing("\n")
    |> String.split("\n")
    |> length()
  end
end
