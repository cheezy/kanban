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

  use Gettext, backend: KanbanWeb.Gettext

  alias Kanban.Tasks.PathSafety

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

  # W1866: the per-item status enum for the OPTIONAL nested
  # `security_considerations.considerations[]` breakdown. Distinct from
  # `@section_status_enum` — a per-consideration mitigation verdict, not a
  # section pass/fail. Absent/nil `considerations` carries no obligation.
  @consideration_status_enum [:mitigated, :partial, :unmitigated]

  # The canonical, single-source-of-truth list of structured review sections a
  # fully-populated `reviewer_result` must carry on a dispatched review. The
  # strict structured-block check (W1066) and every downstream consumer MUST
  # reference this list rather than re-enumerating the keys inline — an inline
  # allow-list is exactly how `project_checks` came to be silently dropped.
  #
  # `status` / `issue_counts` is required in addition to these sections, but as
  # an either/or pair it is enforced separately by `require_status_or_issue_counts/2`
  # rather than listed here.
  @required_review_sections [
    # the categorized issues array — may be empty, but must be present
    :issues,
    # per-criterion acceptance-criteria results the review queue renders
    :acceptance_criteria,
    # the full project checklist verdicts (CODE-REVIEW.md coverage, W1067)
    :project_checks,
    # per-section verdict: were the task's specified tests written
    :testing_strategy,
    # per-section verdict: was `patterns_to_follow` honored
    :patterns,
    # per-section verdict: were the task's `pitfalls` avoided
    :pitfalls,
    # per-section verdict: were the task's `security_considerations` addressed
    :security_considerations,
    # the reviewer schema version that produced this structured block
    :schema_version
  ]

  # Permissive semver: MAJOR.MINOR with optional .PATCH, pre-release, and
  # build metadata. Accepts "1.0", "1.2.3", "2.0.0-beta.1", "1.0+build.7".
  @semver_regex ~r/^\d+\.\d+(\.\d+)?(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$/

  @min_summary_length 40

  @max_diff_lines 500

  # The project checklist count is read ONCE, at compile time, from a copy of
  # `CODE-REVIEW.md` kept under `priv/` — NOT from the repo-root doc.
  #
  # Why `priv/` and not the root: `priv/` is a standard mix application directory
  # that is reliably present in the source tree at compile time AND copied into
  # `mix release` artifacts; a repo-root doc is not an app file and can be absent
  # from a release/Docker build context. Reading the root doc at compile time
  # baked `nil` in production, which — with the unconditional coverage gate —
  # rejected every dispatched-review completion (incident: "checklist could not
  # be read"). `priv/CODE-REVIEW.md` is a verbatim copy of the root checklist,
  # kept in sync by a drift-guard test; the root doc remains the human-facing
  # canonical checklist the reviewer agent reads.
  #
  # @external_resource makes the module recompile when the checklist changes. A
  # top-level bullet is a line beginning with "- " (CRITICAL bullets included);
  # indented context lines and "##" headings are not checks. If the file STILL
  # cannot be read at build time the count is nil and the coverage check FAILS
  # OPEN (coverage simply not enforced) rather than blocking every completion —
  # the other contract checks (section presence, non-empty project_checks,
  # cross-field consistency) keep enforcing. See coverage_shortfall/2.
  @code_review_path [__DIR__, "..", "..", "..", "priv", "CODE-REVIEW.md"]
                    |> Path.join()
                    |> Path.expand()
  @external_resource @code_review_path
  @project_checklist_count (case File.read(@code_review_path) do
                              {:ok, content} ->
                                content
                                |> String.split("\n")
                                |> Enum.count(&String.starts_with?(&1, "- "))

                              {:error, _} ->
                                nil
                            end)

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
  def required_review_sections, do: @required_review_sections

  @doc """
  The number of top-level bullets in the canonical project checklist
  (`CODE-REVIEW.md`), read once at compile time. This is the coverage floor a
  dispatched review's `project_checks` must meet — it is derived from the
  checklist file, never supplied by the client.

  Returns `nil` only if the checklist file could not be read at build time, in
  which case the coverage check FAILS OPEN (coverage is not enforced) rather
  than blocking every completion — the other contract checks still run.
  """
  def project_checklist_count, do: @project_checklist_count

  @doc false
  # The pure coverage decision, exposed for direct testing of every branch
  # (pass, shortfall, and the FAIL-OPEN "checklist unavailable" case). Returns
  # `nil` when coverage is satisfied OR when it cannot be verified, and a
  # human-readable failure message only on a genuine shortfall. `expected` is the
  # baked checklist bullet count; `supplied` is the number of project_checks
  # entries in the review.
  #
  # FAIL OPEN (not closed) when `expected` is unavailable (nil / non-positive):
  # an unreadable checklist must never block every completion in an environment
  # where the file is missing — that bricked production once. Coverage is simply
  # not enforced there; the other contract checks still run.
  def coverage_shortfall(expected, supplied)

  def coverage_shortfall(expected, supplied)
      when is_integer(expected) and expected > 0 and is_integer(supplied) and supplied >= expected,
      do: nil

  def coverage_shortfall(expected, supplied)
      when is_integer(expected) and expected > 0,
      do: coverage_shortfall_message(expected, supplied)

  def coverage_shortfall(_expected, _supplied), do: nil

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
  Returns the **always-reject** "fully populated + consistent" review-contract
  failures for a completion's `reviewer_result` — the subset the gate enforces
  unconditionally (W1070), independent of the `:strict_completion_validation`
  grace flag. Returns `[]` when the contract holds.

  The contract covers exactly the *completeness and consistency* failures, never
  legacy *shape* nits (a malformed issue entry, a bad `schema_version` format) —
  those stay grace-gated in `validate_reviewer_result/2`:

    * a dispatched review must carry every required structured section
      (`required_review_sections/0`) with a non-empty `project_checks` list that
      covers the full checklist; and
    * when a `task` is given, the review must be consistent with it
      (`cross_check_reviewer_result/2`).

  Only a **present, dispatched** review is contract-checked here. A valid
  skip-form review (`"dispatched" => false`), a malformed-`dispatched` map, and
  an absent/nil `reviewer_result` carry no always-reject completeness obligation:
  the first is a legitimate review-less completion, and the latter two remain
  under the grace flag (the `:strict_completion_validation` rollout enforces a
  required review post-rollout, and the plugin-side fix G222 guarantees a
  complete review is always sent). This keeps the grace rollout intact for
  not-yet-updated clients while making an *incomplete present* review
  non-completable in any mode.
  """
  def review_contract_failures(result, task \\ nil)

  def review_contract_failures(%{"dispatched" => true} = result, task) do
    structural =
      []
      |> check_required_structured_block(result, :reviewer, require_structured_block: true)
      |> Enum.reverse()

    structural ++ cross_failures(result, task)
  end

  def review_contract_failures(_result, _task), do: []

  defp cross_failures(_result, nil), do: []

  defp cross_failures(result, task) do
    case cross_check_reviewer_result(result, task) do
      {:ok, _} -> []
      {:error, errors} -> errors
    end
  end

  @doc """
  Returns **grace-gated** acceptance-criteria count failures for a dispatched
  `reviewer_result`, measured against the `task` it describes.

  Unlike `review_contract_failures/2` (which rejects unconditionally), these
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
  def acceptance_criteria_count_failures(result, task)

  def acceptance_criteria_count_failures(%{"dispatched" => true} = result, %{} = task) do
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

  def acceptance_criteria_count_failures(_result, _task), do: []

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

  defp validate(nil, _role, _opts), do: {:error, [{:result, "can't be blank"}]}

  defp validate(result, _role, _opts) when not is_map(result),
    do: {:error, [{:result, "must be a map"}]}

  defp validate(result, role, opts) do
    errors =
      []
      |> check_dispatched(result)
      |> check_summary(result)
      |> check_by_dispatched(result, role)
      |> check_required_structured_block(result, role, opts)

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

  # Per-section verdicts plus the nested security_considerations.considerations[]
  # breakdown. Extracted from check_by_dispatched/3 to keep that function's
  # complexity within the credo ABC ceiling.
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
    |> check_enum(
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

  # D55: when opted in (the strict-validation gate), a dispatched reviewer
  # review must carry the structured block the review queue renders — not
  # merely the legacy summary envelope. Each absent field is named so the
  # client can fix the payload. Presence is the gate; the type checks above
  # still validate the values when the fields are present, and an empty
  # `issues: []` with a `status` is a valid, passing review (not "missing").
  # Only fires for `dispatched: true`; the skip path is untouched.
  defp check_required_structured_block(errors, %{"dispatched" => true} = result, :reviewer, opts) do
    if Keyword.get(opts, :require_structured_block, false) do
      # Drive the presence checks from the single source of truth
      # (@required_review_sections) rather than re-enumerating the keys inline —
      # an inline allow-list is exactly how project_checks came to be dropped.
      @required_review_sections
      |> Enum.reduce(errors, fn section, acc ->
        require_structured_field(acc, result, Atom.to_string(section), section)
      end)
      |> require_status_or_issue_counts(result)
      |> require_non_empty_project_checks(result)
      |> require_project_checks_coverage(result)
    else
      errors
    end
  end

  defp check_required_structured_block(errors, _result, _role, _opts), do: errors

  defp require_structured_field(errors, result, key, field) do
    if Map.has_key?(result, key) do
      errors
    else
      [{field, missing_structured_field_message(key)} | errors]
    end
  end

  defp require_status_or_issue_counts(errors, result) do
    if Map.has_key?(result, "status") or Map.has_key?(result, "issue_counts") do
      errors
    else
      [{:status, missing_status_or_issue_counts_message()} | errors]
    end
  end

  # An empty (or non-list) project_checks is the truncation failure mode: a bare
  # presence check passes an empty list, but an empty list is a dropped/trimmed
  # review. Absence is already reported by the presence check above, so only flag
  # a present-but-empty or present-but-non-list value here. (W1067 adds the
  # full-checklist coverage check on top of this non-empty floor.)
  defp require_non_empty_project_checks(errors, result) do
    case Map.get(result, "project_checks") do
      [_ | _] -> errors
      nil -> errors
      _ -> [{:project_checks, empty_project_checks_message()} | errors]
    end
  end

  # project_checks must account for EVERY top-level checklist bullet, not merely
  # be non-empty — a short count is the D60 truncation defect (3 of 25). The
  # expected count is the compile-time-baked @project_checklist_count, never a
  # client value. Only runs on a non-empty list (absence/empty already reported
  # above), so it never double-reports. A nil baked count (checklist unreadable
  # at build time) fails closed via coverage_shortfall/2.
  defp require_project_checks_coverage(errors, result) do
    case Map.get(result, "project_checks") do
      [_ | _] = checks ->
        case coverage_shortfall(@project_checklist_count, length(checks)) do
          nil -> errors
          message -> [{:project_checks, message} | errors]
        end

      _ ->
        errors
    end
  end

  defp missing_structured_field_message(key) do
    gettext(
      "is required on a dispatched review: the structured %{field} field the review queue renders is missing",
      field: key
    )
  end

  defp missing_status_or_issue_counts_message do
    gettext(
      "is required on a dispatched review: include either status or issue_counts so the review queue can render the verdict"
    )
  end

  defp empty_project_checks_message do
    gettext(
      "is required on a dispatched review: project_checks must be a non-empty list covering the project checklist"
    )
  end

  defp coverage_shortfall_message(expected, supplied) do
    gettext(
      "is incomplete: project_checks covers %{supplied} of the %{expected} project checklist bullets; every checklist bullet must be evaluated",
      expected: expected,
      supplied: supplied
    )
  end

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

  # D114: the changed_files path is fully attacker-controlled (public
  # PUT /api/tasks/:id/changed_files). Reject absolute paths, `..` traversal, and
  # null bytes so a stored path cannot escape the repo root — parity with the
  # key_files embed, via the shared Kanban.Tasks.PathSafety predicate.
  defp check_changed_file_path(errors, entry, idx) do
    case entry |> Map.get("path") |> PathSafety.validate() do
      :ok ->
        errors

      {:error, reason} ->
        [{:changed_file_path, changed_file_path_error(idx, reason)} | errors]
    end
  end

  defp changed_file_path_error(idx, reason) when reason in [:empty, :not_a_string],
    do: "changed_files[#{idx}] must have a non-empty string \"path\""

  defp changed_file_path_error(idx, :absolute),
    do: "changed_files[#{idx}] \"path\" must be a relative path, not absolute"

  defp changed_file_path_error(idx, :traversal),
    do: "changed_files[#{idx}] \"path\" must not contain .. path traversal"

  defp changed_file_path_error(idx, :null_byte),
    do: "changed_files[#{idx}] \"path\" must not contain a null byte"

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
