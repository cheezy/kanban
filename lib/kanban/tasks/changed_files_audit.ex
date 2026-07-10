defmodule Kanban.Tasks.ChangedFilesAudit do
  @moduledoc """
  Detects — non-blocking — when a review-bound task lands in the Review column
  with its work having changed files but no `changed_files` diff uploaded: the
  "empty `changed_files` in review" gap (goal G321, task D128).

  This is a DETECT-AND-FLAG safety net, not a hard gate. The completion still
  succeeds; the task still enters Review. What this adds is visibility: a
  `[:kanban, :task, :changed_files_missing]` telemetry event plus a structured
  warning, so a review task that arrived with no file diffs is queryable and
  loud instead of silently blind (the reviewer sees every line as UNKNOWN).

  The check is false-positive-free: it fires only when `actual_files_changed`
  is non-empty (the work genuinely changed files) **and** `changed_files` is
  empty (the diff was lost). A legitimate no-op change — both empty — is never
  flagged, and a task that did upload its diff is never flagged.

  The upstream fix for *why* the diff went missing lives in the plugin hook
  (task D127: target the changed_files upload by the `/complete` URL task id).
  This module is the server-side safety net for when it still slips through.
  """

  import Ecto.Query, warn: false

  alias Kanban.Repo
  alias Kanban.Tasks.Task

  require Logger

  @telemetry_event [:kanban, :task, :changed_files_missing]
  @review_column_name "Review"

  @doc """
  Audits a review-bound task for a missing `changed_files` diff.

  Best-effort and non-blocking: emits a telemetry event and a warning when the
  diff is missing, and always returns the task unchanged so it can be dropped
  into the completion pipeline without altering control flow.
  """
  @spec audit_review_bound_task(Task.t(), integer() | nil) :: Task.t()
  def audit_review_bound_task(%Task{} = task, board_id) do
    if diff_missing?(task) do
      :telemetry.execute(
        @telemetry_event,
        %{count: 1},
        %{task_id: task.id, identifier: task.identifier, board_id: board_id}
      )

      Logger.warning(
        "Review-bound task #{task.identifier} (id #{task.id}) reached Review with " <>
          "changed_files empty but actual_files_changed present — the review will show " <>
          "no file diffs. The changed_files upload was likely lost (G321/D128)."
      )
    end

    task
  end

  @doc """
  Whether a task's diff is missing: it recorded changed files
  (`actual_files_changed` is non-empty) but has no `changed_files` diff.

  Returns `false` for a genuine no-op change (both empty) and for a task that
  did upload its diff.
  """
  @spec diff_missing?(Task.t()) :: boolean()
  def diff_missing?(%Task{} = task) do
    files_changed?(task.actual_files_changed) and empty_changed_files?(task.changed_files)
  end

  @doc """
  Scans every task currently in a Review column for a missing `changed_files`
  diff and alerts on each hit.

  Unlike `audit_review_bound_task/2` — which fires only at the instant a task
  transitions into Review — this is a standing sweep over all rows already in
  the Review column, so a gap that slipped through (e.g. D110/D114, where the
  diff upload was lost before the safety net existed) is still surfaced after
  the fact. Each diff-missing task re-emits the same
  `[:kanban, :task, :changed_files_missing]` telemetry event and warning via
  `audit_review_bound_task/2` — no second alerting path.

  Returns the list of diff-missing review tasks (each with `:column`
  preloaded), so a caller (a Mix task, a scheduled job) can report them.
  """
  @spec scan_missing_diffs() :: [Task.t()]
  def scan_missing_diffs do
    from(t in Task,
      join: c in assoc(t, :column),
      as: :column,
      where: c.name == ^@review_column_name and is_nil(t.archived_at),
      preload: [column: c]
    )
    |> Repo.all()
    |> Enum.filter(&diff_missing?/1)
    |> Enum.map(fn task -> audit_review_bound_task(task, task.column.board_id) end)
  end

  defp files_changed?(actual_files_changed) when is_binary(actual_files_changed),
    do: String.trim(actual_files_changed) != ""

  defp files_changed?(_), do: false

  defp empty_changed_files?(nil), do: true
  defp empty_changed_files?([]), do: true
  defp empty_changed_files?(list) when is_list(list), do: false
  defp empty_changed_files?(_), do: false
end
