defmodule Kanban.Archives.Retention do
  @moduledoc """
  Removes archived tasks older than a cutoff, in batches, for
  `Kanban.Retention.PurgeWorker`. Reached through
  `Kanban.Archives.purge_archived_before/2`.

  A task is removed when its `archived_at` is strictly older than the cutoff,
  except:

    * a goal while any of its children is not archived, or was archived at or
      after the cutoff, so a goal never disappears from under live work and no
      kept child loses its goal;
    * a task that an unarchived task on the same board still lists in its
      `dependencies`, mirroring the `:has_dependents` refusal of
      `Kanban.Tasks.Lifecycle.delete_task/1`.

  Rows are removed `batch_size` at a time with one `DELETE` per batch, so a
  large backlog never holds one long lock; the loop stops when a batch removes
  fewer rows than the batch size. It deliberately does not call
  `Kanban.Tasks.Lifecycle.delete_task/1`, which reorders live tasks,
  broadcasts, emits per-task telemetry and deletes a goal whose last child
  goes: none of that applies to rows already off the board. The database
  removes each task's history, comments, notifications, claim-expiry reports
  and labels with it, and clears `parent_id` and `duplicate_of_id` on any task
  that pointed at it. Running it again with the same cutoff removes nothing.
  """
  import Ecto.Query, warn: false

  alias Kanban.Columns.Column
  alias Kanban.Repo
  alias Kanban.Tasks.Task

  @doc """
  Deletes archived tasks archived before `cutoff`, `batch_size` at a time, and
  returns `{tasks_removed, batches_run}`. An empty result returns `{0, 1}`.
  """
  @spec purge_archived_before(DateTime.t(), pos_integer()) ::
          {non_neg_integer(), pos_integer()}
  def purge_archived_before(%DateTime{} = cutoff, batch_size)
      when is_integer(batch_size) and batch_size > 0 do
    delete_batches(DateTime.truncate(cutoff, :second), batch_size, 0, 0)
  end

  defp delete_batches(cutoff, batch_size, removed, batches) do
    {count, _rows} =
      from(t in Task, where: t.id in subquery(eligible_ids(cutoff, batch_size)))
      |> Repo.delete_all()

    removed = removed + count
    batches = batches + 1

    if count < batch_size,
      do: {removed, batches},
      else: delete_batches(cutoff, batch_size, removed, batches)
  end

  defp eligible_ids(cutoff, batch_size) do
    from(t in Task,
      as: :task,
      where: not is_nil(t.archived_at) and t.archived_at < ^cutoff,
      where: not exists(kept_children(cutoff)),
      where: not exists(unarchived_dependents()),
      order_by: t.id,
      limit: ^batch_size,
      select: t.id
    )
  end

  defp kept_children(cutoff) do
    from(c in Task,
      where: c.parent_id == parent_as(:task).id,
      where: is_nil(c.archived_at) or c.archived_at >= ^cutoff,
      select: 1
    )
  end

  defp unarchived_dependents do
    from(d in Task,
      join: dc in Column,
      on: dc.id == d.column_id,
      join: tc in Column,
      on: tc.id == parent_as(:task).column_id,
      where: dc.board_id == tc.board_id and is_nil(d.archived_at),
      where: fragment("? && ARRAY[?]::varchar[]", d.dependencies, parent_as(:task).identifier),
      select: 1
    )
  end
end
