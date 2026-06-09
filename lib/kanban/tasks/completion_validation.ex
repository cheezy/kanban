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

  # The canonical project checklist (`CODE-REVIEW.md`) is read ONCE, at compile
  # time, and its top-level bullet count baked in as @project_checklist_count.
  # Compile-time (not runtime) on purpose: the file lives at the repo root, which
  # is present at build time but NOT inside a deployed release — a runtime read
  # of that path would fail in production and block every completion. @external_resource
  # makes the module recompile when the checklist changes, so the count stays
  # current. A top-level bullet is a line beginning with "- " (CRITICAL bullets
  # included); indented context lines and "##" headings are not checks. If the
  # file cannot be read at build time the count is nil and the coverage check
  # fails closed at request time (see coverage_shortfall/2).
  @code_review_path [__DIR__, "..", "..", "..", "CODE-REVIEW.md"] |> Path.join() |> Path.expand()
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
  which case the coverage check fails closed (rejects) rather than letting an
  unverified review through.
  """
  def project_checklist_count, do: @project_checklist_count

  @doc false
  # The pure coverage decision, exposed for direct testing of every branch
  # (pass, shortfall, and the fail-closed "checklist unavailable" case). Returns
  # `nil` when coverage is satisfied, or a human-readable failure message.
  # `expected` is the baked checklist bullet count; `supplied` is the number of
  # project_checks entries in the review.
  def coverage_shortfall(expected, supplied)

  def coverage_shortfall(expected, supplied)
      when is_integer(expected) and expected > 0 and is_integer(supplied) and supplied >= expected,
      do: nil

  def coverage_shortfall(expected, supplied)
      when is_integer(expected) and expected > 0,
      do: coverage_shortfall_message(expected, supplied)

  def coverage_shortfall(_expected, _supplied), do: checklist_unavailable_message()

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

  defp checklist_unavailable_message do
    gettext(
      "cannot be verified: the project checklist file could not be read, so project_checks coverage cannot be confirmed"
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
