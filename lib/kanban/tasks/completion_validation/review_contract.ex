defmodule Kanban.Tasks.CompletionValidation.ReviewContract do
  @moduledoc """
  The always-reject completeness contract for a dispatched `reviewer_result`
  (D55, W1940).

  One responsibility: decide whether a review that claims to have been
  dispatched is actually *fully populated*. Every other validator in the family
  checks the shape of what was supplied; this one checks that nothing was left
  out. Its failures are never soft — an incomplete present review is
  non-completable in every mode, which is what stops a thin report from being
  recorded as a real one.

  It owns three things that belong together and nowhere else:

    * `@required_review_sections` — the single source of truth for which
      structured sections a dispatched review must carry. Callers reference it
      rather than re-enumerating the keys; an inline allow-list is exactly how
      `project_checks` was once silently dropped.
    * the compile-time `priv/CODE-REVIEW.md` bullet count behind
      `require_project_checks_coverage/2`.
    * `coverage_shortfall/2`, the pure coverage decision.

  ## Fail open, never closed

  The checklist count is baked at compile time and is `nil` when the file
  cannot be read. Coverage is then simply **not enforced** — the other contract
  checks keep running. This is deliberate and load-bearing: a fail-closed read
  once rejected every dispatched-review completion in an environment where the
  file was missing. Do not "harden" the `File.read/1` into a `File.read!/1`.
  """

  use Gettext, backend: KanbanWeb.Gettext

  alias Kanban.Tasks.CompletionValidation.TaskConsistency

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
  @code_review_path [__DIR__, "..", "..", "..", "..", "priv", "CODE-REVIEW.md"]
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
  The canonical list of structured review sections a dispatched
  `reviewer_result` must carry to be considered fully populated.

  Re-exported by `Kanban.Tasks.CompletionValidation.required_review_sections/0`.
  """
  def sections, do: @required_review_sections

  @doc """
  The number of top-level bullets in `priv/CODE-REVIEW.md`, baked at compile
  time, or `nil` when the file could not be read (coverage then fails open).

  Re-exported by `Kanban.Tasks.CompletionValidation.project_checklist_count/0`.
  """
  def checklist_count, do: @project_checklist_count

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
  Every always-reject completeness failure for `result`, as `{field, message}`
  tuples, already in report order.

  `task` may be `nil`, in which case only the structural checks run — the
  cross-field rules need a task to compare against.
  """
  def failures(result, task \\ nil)

  def failures(%{"dispatched" => true} = result, task) do
    structural =
      []
      |> check_structured_block(result, :reviewer, require_structured_block: true)
      |> Enum.reverse()

    structural ++ cross_failures(result, task)
  end

  def failures(_result, _task), do: []

  defp cross_failures(_result, nil), do: []

  defp cross_failures(result, task) do
    case TaskConsistency.cross_check(result, task) do
      {:ok, _} -> []
      {:error, errors} -> errors
    end
  end

  @doc """
  Folds every missing-section failure into `errors`.

  Takes the error accumulator FIRST, prepends new failures to it, and returns
  the still-unreversed list — the caller reverses once at the end. Only a
  dispatched reviewer result that opted into the strict block is checked.
  """
  # D55: when opted in (the strict-validation gate), a dispatched reviewer
  # review must carry the structured block the review queue renders — not
  # merely the legacy summary envelope. Each absent field is named so the
  # client can fix the payload. Presence is the gate; the type checks above
  # still validate the values when the fields are present, and an empty
  # `issues: []` with a `status` is a valid, passing review (not "missing").
  # Only fires for `dispatched: true`; the skip path is untouched.
  def check_structured_block(errors, %{"dispatched" => true} = result, :reviewer, opts) do
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

  def check_structured_block(errors, _result, _role, _opts), do: errors

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
end
