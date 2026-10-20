defmodule Kanban.Tasks.Archiving do
  @moduledoc """
  Archiving tasks: archive (with the goal-to-children cascade), unarchive,
  and the board-scoped bulk archive of old completed tasks.

  Extracted from `Kanban.Tasks.Lifecycle` (W2350) to keep that module under
  the size cap. The archive and unarchive writes, their `TaskTelemetry`
  events, the `[:kanban, :task, :bulk_archived]` event and the PubSub
  `:task_updated` broadcasts all live here, in the same order as before:
  persist, then telemetry, then broadcast.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Kanban.Repo
  alias Kanban.Tasks.Broadcaster
  alias Kanban.Tasks.Positioning
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskTelemetry
  alias Kanban.Workspaces.Policy

  @doc """
  Archives a task by stamping `archived_at` and persisting optional
  archive metadata.

  When the task is a `:goal`, its non-archived child tasks are
  cascade-archived in the same transaction so the Archive view never
  shows orphaned children of an archived parent. Child attrs are
  derived from the parent's attrs:

    * `archive_reason`: inherits the parent's reason when it is
      `:completed | :wontdo | :deferred | :cancelled`; defaults to
      `:completed` when the parent has no reason or was archived as a
      `:duplicate` (children are not duplicates of whatever the parent
      was a duplicate of).
    * `archive_note`: inherits the parent's note only when the reason
      is one that requires it (`:wontdo | :deferred | :cancelled`).
    * `archived_by_id`: inherits the parent's value.
    * `duplicate_of_id`: never inherited.
    * `archived_at`: same timestamp as the parent's archive (so the
      batch groups cleanly in the Archive view).

  ## Attrs

  When `attrs` is empty (the default), only `archived_at` is set — the
  task looks identical to the legacy archive flow. Callers that want to
  surface a reason on the Archive view pass any subset of:

    * `:archive_reason` — one of `:completed`, `:duplicate`, `:wontdo`,
      `:deferred`, `:cancelled`
    * `:archive_note` — required when `:archive_reason` is `:wontdo`,
      `:deferred`, or `:cancelled`
    * `:duplicate_of_id` — required when `:archive_reason` is `:duplicate`,
      forbidden otherwise
    * `:archived_by_id` — FK to the user performing the archive

  All validation runs through `Task.changeset/2`, so the conditional
  required-field rules introduced in W570 are enforced here. The
  PubSub `:task_updated` event is broadcast for the parent and for each
  cascade-archived child so open ArchiveLive / BoardLive sessions
  refresh.
  """
  def archive_task(%Task{} = task, attrs \\ %{}) do
    attrs_map = Map.new(attrs)
    archived_at = DateTime.utc_now() |> DateTime.truncate(:second)
    archive_attrs = Map.put(attrs_map, :archived_at, archived_at)

    Multi.new()
    |> Multi.update(:goal, Task.archive_changeset(task, archive_attrs))
    |> Multi.run(:children, fn repo, %{goal: archived_goal} ->
      cascade_archive_children(repo, archived_goal, attrs_map, archived_at)
    end)
    |> Repo.transaction()
    |> handle_archive_result()
  end

  defp handle_archive_result({:ok, %{goal: updated_task, children: children}}) do
    emit_archive_telemetry(updated_task)
    Broadcaster.broadcast_task_change(updated_task, :task_updated)

    Enum.each(children, fn child ->
      emit_cascade_telemetry(child, updated_task.id)
      Broadcaster.broadcast_task_change(child, :task_updated)
    end)

    {:ok, updated_task}
  end

  defp handle_archive_result({:error, _step, changeset, _changes}), do: {:error, changeset}

  defp emit_archive_telemetry(task), do: TaskTelemetry.archived(task)

  defp emit_cascade_telemetry(child, goal_id),
    do: TaskTelemetry.archived(child, %{via: :goal_cascade, goal_id: goal_id})

  defp cascade_archive_children(_repo, %Task{type: type}, _parent_attrs, _archived_at)
       when type != :goal do
    {:ok, []}
  end

  defp cascade_archive_children(repo, %Task{id: goal_id}, parent_attrs, archived_at) do
    child_attrs = build_child_archive_attrs(parent_attrs, archived_at)

    children =
      from(t in Task,
        where: t.parent_id == ^goal_id and is_nil(t.archived_at)
      )
      |> repo.all()

    Enum.reduce_while(children, {:ok, []}, fn child, {:ok, acc} ->
      child
      |> Task.archive_changeset(child_attrs)
      |> repo.update()
      |> case do
        {:ok, archived} -> {:cont, {:ok, [archived | acc]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  @parent_reasons_that_inherit_to_children [:completed, :wontdo, :deferred, :cancelled]
  @parent_reasons_that_require_note [:wontdo, :deferred, :cancelled]

  defp build_child_archive_attrs(parent_attrs, archived_at) do
    parent_reason = Map.get(parent_attrs, :archive_reason)
    {child_reason, include_note?} = child_reason_for(parent_reason)

    %{archived_at: archived_at, archive_reason: child_reason}
    |> maybe_put(:archived_by_id, Map.get(parent_attrs, :archived_by_id))
    |> maybe_put_note(include_note?, Map.get(parent_attrs, :archive_note))
  end

  defp child_reason_for(reason) when reason in @parent_reasons_that_inherit_to_children do
    {reason, reason in @parent_reasons_that_require_note}
  end

  # nil, :duplicate, or any unexpected value → children are :completed,
  # not duplicates of whatever the parent was a duplicate of.
  defp child_reason_for(_), do: {:completed, false}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_note(map, false, _note), do: map
  defp maybe_put_note(map, true, nil), do: map
  defp maybe_put_note(map, true, note), do: Map.put(map, :archive_note, note)

  @doc """
  Unarchives a task by clearing `archived_at` and every archive-metadata
  field so the restored task looks fully alive again.

  Per W572 pitfall #3, leaving `archive_reason` set on a restored task
  would surface it on the Archive view's per-reason filter — not what
  the user expects after pressing "Restore".

  An assignee who no longer has write access to the board (removed from it,
  or lowered to read-only, since the task was archived) is cleared, so the
  restored task is open to be claimed or reassigned.

  Broadcasts the PubSub `:task_updated` event so open archive pages
  drop the row from their list.
  """
  def unarchive_task(%Task{} = task) do
    clear_attrs = %{
      archived_at: nil,
      archive_reason: nil,
      archive_note: nil,
      archived_by_id: nil,
      duplicate_of_id: nil
    }

    case clear_archive_with_fresh_position(task, clear_attrs) do
      {:ok, updated_task} ->
        TaskTelemetry.unarchived(updated_task)

        Broadcaster.broadcast_task_change(updated_task, :task_updated)

        {:ok, updated_task}

      {:error, _} = error ->
        error
    end
  end

  # Clears the archive fields AND assigns a fresh live position in one
  # transaction. The (column_id, position) unique index is partial on
  # archived_at, so an archived task can share a position value with a live
  # one; clearing archived_at without re-positioning would violate the live
  # constraint. get_next_position_locked takes a transactional advisory lock,
  # hence the surrounding Repo.transaction.
  defp clear_archive_with_fresh_position(task, clear_attrs) do
    Repo.transaction(fn ->
      column = Kanban.Columns.get_column!(task.column_id)
      next_position = Positioning.get_next_position_locked(column)

      changeset =
        task
        |> Task.archive_changeset(clear_attrs)
        |> Ecto.Changeset.put_change(:position, next_position)
        |> drop_assignee_without_write_access(task, column)

      case Repo.update(changeset) do
        {:ok, updated_task} -> updated_task
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  # Removing someone from a board, or lowering them to read-only, unassigns
  # them from its open tasks but leaves archived ones alone. A task restored
  # after that would come back assigned to someone who can no longer work it,
  # and Tasks.get_next_task would never offer it to anyone else, so an
  # assignee without write access to the board, read from the database, is
  # cleared here.
  defp drop_assignee_without_write_access(changeset, %Task{assigned_to_id: nil}, _column),
    do: changeset

  defp drop_assignee_without_write_access(changeset, %Task{assigned_to_id: user_id}, column) do
    if Policy.effective_board_access(column.board_id, user_id) in [:owner, :modify],
      do: changeset,
      else: Ecto.Changeset.put_change(changeset, :assigned_to_id, nil)
  end

  @doc """
  Archives every completed, non-archived task on the given board whose
  `completed_at` is strictly older than the cutoff (default 30 days).

  Uses a single `Repo.update_all` to avoid N+1 writes when the Done
  column contains many tasks. Returns `{:ok, count}` where `count` is
  the number of tasks archived.

  Emits a `[:kanban, :task, :bulk_archived]` telemetry event with
  `%{count: count}` measurements and `%{board_id: board_id}` metadata.

  Scoped strictly to the supplied board — completed tasks on other
  boards are never touched. Tasks whose `completed_at` is `nil` are
  also skipped (their age is unknown), as are tasks already archived
  or whose `status` is not `:completed`.
  """
  def bulk_archive_completed_tasks_older_than(board_id, cutoff_days \\ 30)
      when is_integer(cutoff_days) and cutoff_days >= 0 do
    archived_at = DateTime.utc_now() |> DateTime.truncate(:second)
    cutoff = DateTime.add(archived_at, -cutoff_days * 86_400, :second)

    {count, _} =
      from(t in Task,
        join: c in assoc(t, :column),
        where: c.board_id == ^board_id,
        where: t.status == :completed,
        where: not is_nil(t.completed_at),
        where: t.completed_at < ^cutoff,
        where: is_nil(t.archived_at)
      )
      |> Repo.update_all(
        set: [
          archived_at: archived_at,
          archive_reason: :completed,
          updated_at: archived_at
        ]
      )

    emit_bulk_archive_telemetry(count, board_id)

    {:ok, count}
  end

  defp emit_bulk_archive_telemetry(count, board_id) do
    Kanban.Telemetry.emit([:kanban, :task, :bulk_archived], %{count: count}, %{
      board_id: board_id
    })
  end
end
