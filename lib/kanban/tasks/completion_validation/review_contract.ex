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

  It owns one thing that belongs here and nowhere else:
  `@required_review_sections` — the single source of truth for which structured
  sections a dispatched review must carry. Callers reference it rather than
  re-enumerating the keys; an inline allow-list is exactly how `project_checks`
  was once silently dropped.

  ## The project checklist is optional, and its length is not ours to judge

  `project_checks` carries one verdict per top-level bullet of the *calling
  project's* root `CODE-REVIEW.md` — a file this server never receives. Only
  the resulting array arrives. Two rules follow, and both are load-bearing:

    * **An empty `project_checks` is valid.** `[]` is precisely what the
      reviewer agent emits for a project with no `CODE-REVIEW.md`
      (`stride/agents/task-reviewer.md`), and the checklist is optional by
      design. Rejecting `[]` forces every project on the dispatched-review path
      to author a checklist it never opted into.
    * **Never gate on the array's length.** There is no server-side ground
      truth for how many bullets the caller's file has. This module once baked
      a bullet count from Kanban's *own* checklist and applied it to every
      project's review, so a caller with a shorter checklist could never
      complete a task (D-report 2026-07-27: "covers 9 of the 25"). The count
      was real; it was measuring the wrong file. Do not reintroduce a fixed
      floor — if coverage must be verified again, the total has to come from
      the reviewer that actually read the file.
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
    # the calling project's checklist verdicts — one per CODE-REVIEW.md bullet,
    # or `[]` when that project has no checklist. Present-but-empty is valid.
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

  @doc """
  The canonical list of structured review sections a dispatched
  `reviewer_result` must carry to be considered fully populated.

  Re-exported by `Kanban.Tasks.CompletionValidation.required_review_sections/0`.
  """
  def sections, do: @required_review_sections

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
      |> require_list_project_checks(result)
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

  # `project_checks` must be a LIST when present — nothing more. `[]` is valid
  # (the project has no CODE-REVIEW.md; the checklist step is simply skipped),
  # and the length of a non-empty list is never judged: only the reviewer that
  # read the caller's checklist knows how many bullets it has. See the moduledoc.
  # Absence of the key is already reported by the presence check above, so only a
  # present-but-non-list value is flagged here.
  defp require_list_project_checks(errors, result) do
    case Map.get(result, "project_checks") do
      checks when is_list(checks) -> errors
      nil -> errors
      _ -> [{:project_checks, non_list_project_checks_message()} | errors]
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

  defp non_list_project_checks_message do
    gettext(
      "must be a list on a dispatched review: one entry per project checklist bullet, or an empty list when the project has no CODE-REVIEW.md"
    )
  end
end
