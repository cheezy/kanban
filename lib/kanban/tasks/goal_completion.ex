defmodule Kanban.Tasks.GoalCompletion do
  @moduledoc """
  Transactional last-child-completion detection for parent goals.

  Provides the building block for the after_goal hook protocol (G113):
  given a child task being completed, atomically transition the child to
  `:completed` and determine whether this completion is the final
  remaining child of its parent goal. Concurrent sibling completions are
  serialized by a row-level `FOR UPDATE` lock on the parent goal, so
  exactly one completion sees `:last_child` — even if many siblings call
  this function simultaneously.

  Downstream wiring is owned by sibling tasks; this module is the
  serialization primitive they sit on top of:

  * W491 — wire `after_goal` into the completion endpoint response when
    `:last_child` is detected
  * W492 — same for `mark_reviewed`
  * W493 — gate the parent goal's Done transition on the agent-reported
    after_goal exit code (this is why `finalize_child_and_check_goal_complete/2`
    does NOT itself mark the parent goal `:completed` — promotion is
    deferred until the agent confirms `after_goal` exited 0).
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Kanban.Repo
  alias Kanban.Tasks.Task

  @doc """
  Atomically transition `child` to `:completed` and determine whether the
  transition finished the parent goal.

  Wraps two operations in a single `Ecto.Multi`:

    1. Update the child task with the merged `attrs` (defaults to
       `status: :completed` + `completed_at: utc_now`).
    2. If the child has a parent goal, row-lock the parent (`SELECT ...
       FOR UPDATE`), then count siblings whose `status != :completed`.

  Returns `{:ok, :last_child}` when the parent goal exists and zero
  siblings remain incomplete after this transition; returns
  `{:ok, :not_last_child}` otherwise — including the cases where the
  task has no parent (`parent_id` is nil) or the parent is not of type
  `:goal`. Returns the standard `{:error, step, value, changes_so_far}`
  shape on transaction failure.

  Concurrent calls for siblings of the same parent goal are serialized
  by the parent-goal row lock: only one transaction can hold the lock at
  a time, so each sees a consistent view of the remaining-incomplete
  count when it computes `:last_child` vs `:not_last_child`. The result
  is unambiguous — duplicate `:last_child` returns are not possible.

  Accepts `attrs` as either a map or keyword list; missing `:status` and
  `:completed_at` keys default to `:completed` / `DateTime.utc_now/0`.

  ## Examples

      # Last child of a goal — parent has no other open siblings.
      iex> Tasks.finalize_child_and_check_goal_complete(child)
      {:ok, :last_child}

      # Sibling still open under the same parent goal.
      iex> Tasks.finalize_child_and_check_goal_complete(child)
      {:ok, :not_last_child}

      # Orphan (no parent goal) — always :not_last_child.
      iex> Tasks.finalize_child_and_check_goal_complete(orphan)
      {:ok, :not_last_child}
  """
  @spec finalize_child_and_check_goal_complete(Task.t(), map() | keyword()) ::
          {:ok, :last_child}
          | {:ok, :not_last_child}
          | {:error, atom(), term(), map()}
  def finalize_child_and_check_goal_complete(%Task{} = child, attrs \\ %{}) do
    child
    |> build_done_multi(merge_done_defaults(attrs))
    |> Repo.transaction()
    |> case do
      {:ok, %{goal_check: result}} -> {:ok, result}
      {:error, _step, _value, _changes} = err -> err
    end
  end

  defp merge_done_defaults(attrs) do
    attrs
    |> Map.new()
    |> Map.put_new(:status, :completed)
    |> Map.put_new(:completed_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end

  defp build_done_multi(child, done_attrs) do
    Multi.new()
    |> Multi.update(:child, Ecto.Changeset.change(child, done_attrs))
    |> Multi.run(:goal_check, fn repo, %{child: updated_child} ->
      check_parent_goal_complete(repo, updated_child)
    end)
  end

  # Row-locks the parent goal under the current transaction and inspects
  # remaining open siblings. The lock is the linchpin of the race-freedom
  # guarantee: PostgreSQL holds it until the enclosing transaction
  # commits, so concurrent sibling completions queue behind each other
  # and each sees a consistent post-update sibling count.
  defp check_parent_goal_complete(_repo, %Task{parent_id: nil}), do: {:ok, :not_last_child}

  defp check_parent_goal_complete(repo, %Task{parent_id: parent_id}) do
    case lock_parent_goal(repo, parent_id) do
      %Task{type: :goal} = parent ->
        remaining =
          from(t in Task,
            where: t.parent_id == ^parent_id and t.status != :completed and is_nil(t.archived_at)
          )
          |> repo.aggregate(:count)

        if remaining == 0 do
          # Last child detected. Atomically flip the parent goal into
          # the :pending after_goal state while we still hold the row
          # lock — this is the gate that prevents the existing
          # update_parent_goal_position promotion logic from racing the
          # child completion to move the goal to Done before the agent
          # has reported after_goal (W493).
          maybe_mark_after_goal_pending(repo, parent)
          {:ok, :last_child}
        else
          {:ok, :not_last_child}
        end

      _ ->
        {:ok, :not_last_child}
    end
  end

  # `:pending` is only set when no prior after_goal lifecycle has run
  # for this goal — idempotent re-runs (a sibling that was completed
  # then re-opened then re-completed) never overwrite a later
  # `:succeeded`. The compare-and-set is enforced at the SQL level so a
  # concurrent endpoint update flipping status to `:succeeded` cannot be
  # clobbered by this code path.
  defp maybe_mark_after_goal_pending(repo, %Task{id: goal_id}) do
    from(t in Task,
      where: t.id == ^goal_id and is_nil(t.after_goal_status)
    )
    |> repo.update_all(set: [after_goal_status: :pending])

    :ok
  end

  defp lock_parent_goal(repo, parent_id) do
    from(t in Task, where: t.id == ^parent_id, lock: "FOR UPDATE")
    |> repo.one()
  end
end
