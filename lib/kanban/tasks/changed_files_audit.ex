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

  alias Kanban.Tasks.Task

  require Logger

  @telemetry_event [:kanban, :task, :changed_files_missing]

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

  defp files_changed?(actual_files_changed) when is_binary(actual_files_changed),
    do: String.trim(actual_files_changed) != ""

  defp files_changed?(_), do: false

  defp empty_changed_files?(nil), do: true
  defp empty_changed_files?([]), do: true
  defp empty_changed_files?(list) when is_list(list), do: false
  defp empty_changed_files?(_), do: false
end
