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

  ## Module organization (W1953)

  This module is the single public entry point. The validators themselves live
  in focused siblings under `Kanban.Tasks.CompletionValidation.*`, reached from
  here by `defdelegate` so no caller ever names them directly:

    * `Fields` — the shared leaf-level primitives (enum decoding, section
      notes) every other validator builds on.
    * `ChangedFiles` — the optional `changed_files` array, including the D114
      path-safety guarantee.
    * `BehaviourTestMatrix` — the optional `behaviour_test_matrix` verdict and
      its rows (W1920).
    * `ReviewContract` — the always-reject completeness contract for a
      dispatched review, and the compile-time checklist count (D55, W1940).
    * `AcceptanceCounts` — the grace-gated acceptance-criteria count agreement
      (W1099).
    * `TaskConsistency` — the review-versus-task cross-field rules (W1448).

  What stays here is the envelope: the skip-reason and summary rules every
  result shares, the shape of the optional structured arrays, and the dispatch
  that routes a payload through the siblings.
  """

  alias Kanban.Tasks.CompletionValidation.AcceptanceCounts
  alias Kanban.Tasks.CompletionValidation.BehaviourTestMatrix
  alias Kanban.Tasks.CompletionValidation.ChangedFiles
  alias Kanban.Tasks.CompletionValidation.Fields
  alias Kanban.Tasks.CompletionValidation.ReviewContract

  @skip_reasons [
    :no_subagent_support,
    :small_task_0_1_key_files,
    :trivial_change_docs_only,
    :self_reported_exploration,
    :self_reported_review
  ]

  @severity_enum [:critical, :important, :minor]

  # W1940: the seven recognized `issues[].category` values. The reviewer prompts
  # have always documented seven — `security` for an unmitigated security
  # consideration and `project_check` for a `not_met` CODE-REVIEW.md bullet — but
  # this list carried only five, so a faithful reviewer report was rejected with a
  # hard 422 on the changeset path regardless of the strict feature flag.
  #
  # Order follows the review methodology, with the two additions slotted beside
  # the step they report on. Nothing indexes this list positionally: the sole
  # consumer is the `in`-membership test in `check_enum/6`, and `reviewer_result`
  # persists the *string* value into a `:jsonb` column with no Ecto.Enum and no
  # CHECK constraint — so widening it re-interprets no persisted row.
  @category_enum [
    :acceptance_criteria,
    :pitfall,
    :pattern,
    :testing,
    :security,
    :code_quality,
    :project_check
  ]

  @status_enum [:met, :not_met]

  # W1866: the per-item status enum for the OPTIONAL nested
  # `security_considerations.considerations[]` breakdown. Distinct from
  # `@section_status_enum` — a per-consideration mitigation verdict, not a
  # section pass/fail. Absent/nil `considerations` carries no obligation.
  @consideration_status_enum [:mitigated, :partial, :unmitigated]

  # Permissive semver: MAJOR.MINOR with optional .PATCH, pre-release, and
  # build metadata. Accepts "1.0", "1.2.3", "2.0.0-beta.1", "1.0+build.7".
  @semver_regex ~r/^\d+\.\d+(\.\d+)?(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$/

  @min_summary_length 40

  @doc """
  The exhaustive list of allowed skip-reason atoms.

  Exposed as the single source of truth for API layers, tests, and
  documentation — the same list must appear byte-identical in every plugin
  skill so that server-side aggregation groups identical reasons.
  """
  def skip_reasons, do: @skip_reasons

  @doc """
  The canonical list of structured review sections a dispatched
  `reviewer_result` must carry to be considered fully populated.

  This is the single source of truth for the strict structured-block check.
  Callers MUST reference it rather than re-enumerating the section keys — an
  inline allow-list is exactly how `project_checks` was silently dropped. The
  `status` / `issue_counts` either/or pair is required in addition to these and
  is enforced separately.

  See `docs/completion-contract.md` for the full fully-populated-report contract,
  including the task cross-field rules.
  """
  defdelegate required_review_sections(), to: ReviewContract, as: :sections

  @doc """
  The number of top-level bullets in the project code-review checklist, baked
  at compile time from `priv/CODE-REVIEW.md`.

  `nil` when the file could not be read at build time — coverage is then not
  enforced (it FAILS OPEN). See
  `Kanban.Tasks.CompletionValidation.ReviewContract`.
  """
  defdelegate project_checklist_count(), to: ReviewContract, as: :checklist_count

  @doc false
  defdelegate coverage_shortfall(expected, supplied), to: ReviewContract

  @doc """
  Every always-reject completeness failure for a dispatched `reviewer_result`.

  Returns `{field, message}` tuples in report order, or `[]` when the review is
  complete or was never dispatched. See
  `Kanban.Tasks.CompletionValidation.ReviewContract` for the contract itself.
  """
  defdelegate review_contract_failures(result, task \\ nil), to: ReviewContract, as: :failures

  @doc """
  The allowed per-row `status` values for the OPTIONAL `behaviour_test_matrix`
  verdict, as atoms (W1920).

  Exposed as the assertion surface for the drift guard that keeps this list in
  lockstep with `Kanban.Schemas.Task.BehaviourTestRow.statuses/0`. That schema is
  the source of truth for a persisted row, but this validator is pure and
  Ecto-free (see the moduledoc) and must not depend on an embedded schema — so
  the two lists are kept honest by a test rather than by a call.
  """
  defdelegate behaviour_test_statuses(), to: BehaviourTestMatrix, as: :statuses

  @doc """
  The recognized `reviewer_result.issues[].category` values, as atoms (W1940).

  Exposed as the single source of truth for the surfaces that restate the list
  rather than derive it — the published API schema, the 422 error docs, and the
  markdown API reference. Each of those is hand-maintained, so a drift guard
  asserts them against this function instead of against a duplicated literal.

  Not to be confused with `Kanban.Schemas.Task.BehaviourTestRow.categories/0`,
  which is an unrelated seven-value taxonomy ("Happy path", "Boundary", ...) for
  behaviour-test-matrix rows.
  """
  def issue_categories, do: @category_enum

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
  def validate_explorer_result(result), do: validate(result, :explorer, [])

  @doc """
  Validates a `reviewer_result` payload.

  Same rules as `validate_explorer_result/1`, plus: when `"dispatched"` is
  `true`, also requires `"acceptance_criteria_checked"` and `"issues_found"`
  as non-negative integers.

  ## Options

    * `:require_structured_block` (default `false`) — when `true` and the
      review was dispatched, the structured block the review queue renders
      (`"issues"`, `"acceptance_criteria"`, `"status"`/`"issue_counts"`,
      `"schema_version"`) becomes mandatory; each absent field is reported
      by name. The strict-validation gate passes `true` so a dispatched but
      legacy-only payload is surfaced (warned in grace mode, rejected in
      strict mode). The unconditional schema-layer validator leaves it
      `false`, so the multi-plugin grace rollout (D55/D57) is preserved —
      not-yet-updated clients can still persist legacy payloads until the
      `:strict_completion_validation` flag is flipped.
  """
  def validate_reviewer_result(result, opts \\ []),
    do: validate(result, :reviewer, opts)

  @doc """
  Cross-checks a dispatched `reviewer_result` against the task it describes,
  catching reviews that are internally well-formed but inconsistent with their
  task — e.g. a `not_assessed` security verdict when the task supplied
  `security_considerations` (the D60 defect).

  This is the task-aware counterpart to `validate_reviewer_result/2`, which
  stays a pure result-only check for callers that have no task. The three
  consistency rules live in `Kanban.Tasks.CompletionValidation.TaskConsistency`;
  see its moduledoc and `docs/completion-contract.md`. Returns the same
  `{:ok, result}` / `{:error, [{field, message}, ...]}` shape.
  """
  defdelegate cross_check_reviewer_result(result, task),
    to: Kanban.Tasks.CompletionValidation.TaskConsistency,
    as: :cross_check

  @doc """
  Returns **grace-gated** self-consistency failures for a dispatched
  `reviewer_result` whose optional `security_considerations.considerations[]`
  breakdown contradicts its section verdict (W1866): a `partial`/`unmitigated`
  item cannot coexist with a non-`failed` security verdict.

  Delegates to `Kanban.Tasks.CompletionValidation.TaskConsistency`. Returns a
  bare list (`[]` when consistent / not applicable), mirroring
  `acceptance_criteria_count_failures/2`: the gate warns on these in grace mode
  and rejects only in strict mode. The rule is self-consistency within the
  review, so it needs no `task` argument.
  """
  defdelegate considerations_status_consistency_failures(result),
    to: Kanban.Tasks.CompletionValidation.TaskConsistency

  @doc """
  Returns **grace-gated** acceptance-criteria count failures for a dispatched
  `reviewer_result`, measured against the `task` it describes.

  Unlike `review_contract_failures/2` (which rejects unconditionally), these
  failures follow the `:strict_completion_validation` flag: the gate warns in
  grace mode and rejects with a 422 only in strict mode, matching the documented
  rollout.

  See `Kanban.Tasks.CompletionValidation.AcceptanceCounts` for the comparison
  rules and the W1099 gap this closes.
  """
  defdelegate acceptance_criteria_count_failures(result, task),
    to: AcceptanceCounts,
    as: :failures

  @doc """
  Validates the optional `changed_files` array on the completion payload.

  Returns `{:ok, value}` when valid (including `nil` for legacy payloads
  that omit the field entirely and `[]` for empty arrays), or
  `{:error, [{field, message}, ...]}` listing every failing entry.

  See `Kanban.Tasks.CompletionValidation.ChangedFiles` for the entry rules and
  the path-safety guarantee.
  """
  defdelegate validate_changed_files(value), to: ChangedFiles, as: :validate

  defp validate(nil, _role, _opts), do: {:error, [{:result, "can't be blank"}]}

  defp validate(result, _role, _opts) when not is_map(result),
    do: {:error, [{:result, "must be a map"}]}

  defp validate(result, role, opts) do
    errors =
      []
      |> check_dispatched(result)
      |> check_summary(result)
      |> check_by_dispatched(result, role)
      |> ReviewContract.check_structured_block(result, role, opts)

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
    |> check_review_sections(result)
    |> check_schema_version(result)
  end

  defp check_by_dispatched(errors, %{"dispatched" => true} = result, :explorer) do
    check_duration_ms(errors, result)
  end

  defp check_by_dispatched(errors, %{"dispatched" => false} = result, _role) do
    check_reason(errors, result)
  end

  defp check_by_dispatched(errors, _result, _role), do: errors

  # Per-section verdicts plus the nested security_considerations.considerations[]
  # and behaviour_test_matrix.rows[] breakdowns. Extracted from
  # check_by_dispatched/3 to keep that function's complexity within the credo
  # ABC ceiling.
  defp check_review_sections(errors, result) do
    errors
    |> check_section_verdict(
      result,
      "testing_strategy",
      :testing_strategy_status,
      :testing_strategy_entry
    )
    |> check_section_verdict(result, "patterns", :patterns_status, :patterns_entry)
    |> check_section_verdict(result, "pitfalls", :pitfalls_status, :pitfalls_entry)
    |> check_section_verdict(
      result,
      "security_considerations",
      :security_considerations_status,
      :security_considerations_entry
    )
    |> check_considerations_array(result)
    |> BehaviourTestMatrix.check(result)
  end

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
    |> Fields.check_enum(entry, "severity", @severity_enum, :issue_severity, "issues[#{idx}]")
    |> Fields.check_enum(entry, "category", @category_enum, :issue_category, "issues[#{idx}]")
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
    Fields.check_enum(
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
        |> Fields.check_section_status(verdict, status_field, key)
        |> Fields.check_section_notes(verdict, key)

      _ ->
        [{entry_field, "#{key} must be a map"} | errors]
    end
  end

  # W1866: optional nested `security_considerations.considerations[]` breakdown.
  # When the security_considerations verdict is a map carrying a `considerations`
  # key, it must be a list whose entries are each a map with a non-empty
  # `consideration` string and a `status` in @consideration_status_enum. Absent
  # or nil `considerations` (or a non-map / absent security_considerations
  # verdict) carries no obligation — the array is backwards-compatible. Entry
  # errors use static atom keys with the index embedded in the message, matching
  # `check_issue_entry/3`, so no runtime atoms are created per index.
  defp check_considerations_array(
         errors,
         %{"security_considerations" => %{"considerations" => considerations}}
       )
       when is_list(considerations) do
    considerations
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {entry, idx}, acc -> check_consideration_entry(acc, entry, idx) end)
  end

  # An explicit nil `considerations` is treated exactly like an absent key —
  # backwards-compatible, no obligation.
  defp check_considerations_array(
         errors,
         %{"security_considerations" => %{"considerations" => nil}}
       ),
       do: errors

  defp check_considerations_array(
         errors,
         %{"security_considerations" => %{"considerations" => _}}
       ),
       do: [{:considerations, "security_considerations.considerations must be a list"} | errors]

  defp check_considerations_array(errors, _), do: errors

  defp check_consideration_entry(errors, entry, idx) when is_map(entry) do
    errors
    |> check_consideration_text(entry, idx)
    |> Fields.check_enum(
      entry,
      "status",
      @consideration_status_enum,
      :consideration_status,
      "considerations[#{idx}]"
    )
  end

  defp check_consideration_entry(errors, _entry, idx),
    do: [{:consideration_entry, "considerations[#{idx}] must be a map"} | errors]

  defp check_consideration_text(errors, entry, idx) do
    case Map.get(entry, "consideration") do
      text when is_binary(text) ->
        if String.trim(text) != "" do
          errors
        else
          [{:consideration_text, consideration_text_message(idx)} | errors]
        end

      _ ->
        [{:consideration_text, consideration_text_message(idx)} | errors]
    end
  end

  defp consideration_text_message(idx),
    do: "considerations[#{idx}] must have a non-empty string \"consideration\""

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
end
