defmodule Kanban.Tasks.GoalTelemetry do
  @moduledoc """
  Emits the goal, dependency and after_goal telemetry events through
  `Kanban.Telemetry`.

  The events are declared in `Kanban.Telemetry.Catalog.GoalEvents`. Each is
  emitted only after its change has been committed, so a refused, invalid or
  rolled-back change emits nothing. The functions that take a result return
  it unchanged, so they can sit at the end of a pipe without changing what the
  caller sees, and none of them raises into the caller.

  Metadata carries ids, enum-like atoms and counts only. An after_goal
  attempt's `"output"` is never read: a project's hook can print anything,
  including secrets, so only its exit code and duration are sent.

  A caller that runs a goal completion inside its own transaction, as
  `Kanban.Reviews` does, wraps that transaction in `after_commit/1`. The
  `completed`, `unblocked` and `grace_window_scheduled` events emitted while
  it runs are held back and emitted only once it has returned `{:ok, _}`, so a
  rolled-back transaction emits none of them. The hold is
  `Kanban.Telemetry.AfterCommit`, which also holds
  `Kanban.Tasks.TaskTelemetry.completed/2`.
  """

  import Ecto.Query, only: [from: 2]

  alias Kanban.Columns.Column
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias Kanban.Telemetry.AfterCommit

  @grace_worker_source "after_goal_grace_worker"

  @doc """
  Runs `fun`, a function that runs a database transaction and returns its
  result, and holds back the `completed`, `unblocked` and
  `grace_window_scheduled` events emitted while it runs. They are emitted, in
  order, once `fun` has returned `{:ok, _}`, and dropped otherwise, so they
  only ever report changes that committed. Returns `fun`'s result unchanged.

  Delegates to `Kanban.Telemetry.AfterCommit.after_commit/1`, so every other
  event deferred through that module, such as `[:kanban, :task, :completed]`,
  is held back with them.
  """
  @spec after_commit((-> result)) :: result when result: term()
  defdelegate after_commit(fun), to: AfterCommit

  @doc """
  Emits `[:kanban, :goal, :completed]` for `goal_id`, the id
  `Kanban.Tasks.GoalCompletion.finalize_child/2` returns when a completion
  first completed the goal, or `nil` when it did not.

  Under `after_commit/1` it is held back until that transaction commits.
  Otherwise, inside a transaction it emits nothing, because the completion
  has not committed yet and no caller would emit it afterwards.
  """
  @spec completed(integer() | nil, integer() | nil) :: :ok
  def completed(nil, _board_id), do: :ok

  def completed(goal_id, board_id) when is_integer(goal_id) do
    emit = fn ->
      Kanban.Telemetry.emit([:kanban, :goal, :completed], %{count: 1}, %{
        goal_id: goal_id,
        board_id: board_id
      })
    end

    cond do
      AfterCommit.holding?() -> AfterCommit.defer(emit)
      Repo.in_transaction?() -> :ok
      true -> emit.()
    end
  end

  @doc """
  Emits `[:kanban, :task, :unblocked]` when `result` is a dependent task whose
  blocking status was just recomputed and is no longer `:blocked`. Returns
  `result`.
  """
  @spec unblocked(result, integer()) :: result when result: term()
  def unblocked({:ok, %Task{status: status} = task} = result, board_id)
      when status != :blocked do
    metadata = %{task_id: task.id, board_id: board_id}

    AfterCommit.defer(fn ->
      Kanban.Telemetry.emit([:kanban, :task, :unblocked], %{count: 1}, metadata)
    end)

    result
  end

  def unblocked(result, _board_id), do: result

  @doc """
  Emits `[:kanban, :goal, :promoted_to_ready]` when `result` reports that at
  least one task of `goal` moved to Ready. Returns `result`.
  """
  @spec promoted_to_ready(result, Task.t(), integer()) :: result when result: term()
  def promoted_to_ready({:ok, count} = result, %Task{} = goal, board_id)
      when is_integer(count) and count > 0 do
    Kanban.Telemetry.emit(
      [:kanban, :goal, :promoted_to_ready],
      %{count: 1, task_count: count},
      %{goal_id: goal.id, board_id: board_id}
    )

    result
  end

  def promoted_to_ready(result, _goal, _board_id), do: result

  @doc """
  Emits `[:kanban, :goal, :after_goal_succeeded]` for a goal that was just
  moved to Done by `attempt`. `source` is `:grace_worker` for the grace
  worker's synthetic attempt and `:agent` otherwise; `duration_ms` is
  measured only for an agent report that carries an integer one. A grace
  worker promotion also emits `[:kanban, :goal, :grace_window_expired]`.
  """
  @spec after_goal_succeeded(Task.t(), map()) :: :ok
  def after_goal_succeeded(%Task{} = goal, attempt) do
    metadata = %{goal_id: goal.id, board_id: board_id(goal)}

    case attempt_source(attempt) do
      :agent ->
        Kanban.Telemetry.emit(
          [:kanban, :goal, :after_goal_succeeded],
          with_duration(%{count: 1}, attempt),
          Map.put(metadata, :source, :agent)
        )

      :grace_worker ->
        Kanban.Telemetry.emit(
          [:kanban, :goal, :after_goal_succeeded],
          %{count: 1},
          Map.put(metadata, :source, :grace_worker)
        )

        Kanban.Telemetry.emit([:kanban, :goal, :grace_window_expired], %{count: 1}, metadata)
    end
  end

  @doc """
  Emits `[:kanban, :goal, :after_goal_failed]` when `result` is a goal whose
  failed after_goal `attempt` was recorded. Only the attempt's exit code and
  duration are sent, never its output. Returns `result`.
  """
  @spec after_goal_failed(result, map()) :: result when result: term()
  def after_goal_failed({:ok, %Task{} = goal} = result, attempt) do
    Kanban.Telemetry.emit(
      [:kanban, :goal, :after_goal_failed],
      with_duration(%{count: 1}, attempt),
      %{goal_id: goal.id, board_id: board_id(goal), exit_code: attempt_exit_code(attempt)}
    )

    result
  end

  def after_goal_failed(result, _attempt), do: result

  @doc """
  Emits `[:kanban, :goal, :grace_window_scheduled]` when `result` is the
  inserted grace-window job for `goal`. Returns `result`.
  """
  @spec grace_window_scheduled(result, Task.t(), non_neg_integer()) :: result
        when result: term()
  def grace_window_scheduled({:ok, %Oban.Job{}} = result, %Task{} = goal, window_ms) do
    metadata = %{goal_id: goal.id, board_id: board_id(goal)}

    AfterCommit.defer(fn ->
      Kanban.Telemetry.emit(
        [:kanban, :goal, :grace_window_scheduled],
        %{count: 1, grace_window_ms: window_ms},
        metadata
      )
    end)

    result
  end

  def grace_window_scheduled(result, _goal, _window_ms), do: result

  @doc """
  Emits `[:kanban, :goal, :reassigned]` when `result` is a committed
  reassignment by the user in `scope`. Returns `result`.
  """
  @spec reassigned(result, map() | nil) :: result when result: term()
  def reassigned({:ok, %{moved: [%Task{} = goal | _], skipped: _}} = result, scope) do
    Kanban.Telemetry.emit(
      [:kanban, :goal, :reassigned],
      intervention_counts(result),
      Map.put(intervention_metadata(goal, scope), :assigned_to_id, goal.assigned_to_id)
    )

    result
  end

  def reassigned(result, _scope), do: result

  @doc """
  Emits `[:kanban, :goal, :reprioritized]` when `result` is a committed
  priority change to `priority` by the user in `scope`. Returns `result`.
  """
  @spec reprioritized(result, map() | nil, atom()) :: result when result: term()
  def reprioritized({:ok, %{moved: [%Task{} = goal | _], skipped: _}} = result, scope, priority) do
    Kanban.Telemetry.emit(
      [:kanban, :goal, :reprioritized],
      intervention_counts(result),
      Map.put(intervention_metadata(goal, scope), :priority, priority)
    )

    result
  end

  def reprioritized(result, _scope, _priority), do: result

  @doc """
  Emits `[:kanban, :goal, :reassignment_undone]` (for `:assigned_to_id`) or
  `[:kanban, :goal, :reprioritization_undone]` (for `:priority`) when
  `result` is a committed undo by the user in `scope`. Returns `result`.
  """
  @spec undone(result, :assigned_to_id | :priority, map() | nil) :: result when result: term()
  def undone({:ok, %{moved: [%Task{} = goal | _], skipped: _}} = result, :assigned_to_id, scope) do
    Kanban.Telemetry.emit(
      [:kanban, :goal, :reassignment_undone],
      intervention_counts(result),
      intervention_metadata(goal, scope)
    )

    result
  end

  def undone({:ok, %{moved: [%Task{} = goal | _], skipped: _}} = result, :priority, scope) do
    Kanban.Telemetry.emit(
      [:kanban, :goal, :reprioritization_undone],
      intervention_counts(result),
      intervention_metadata(goal, scope)
    )

    result
  end

  def undone(result, _field, _scope), do: result

  # `moved` lists the goal itself first, so the children are the rest.
  defp intervention_counts({:ok, %{moved: [_goal | children], skipped: skipped}}) do
    %{count: 1, moved_count: length(children), skipped_count: length(skipped)}
  end

  defp intervention_metadata(goal, scope) do
    %{goal_id: goal.id, board_id: board_id(goal), actor_user_id: actor_id(scope)}
  end

  defp actor_id(%{user: %{id: id}}), do: id
  defp actor_id(_scope), do: nil

  defp attempt_source(%{"source" => @grace_worker_source}), do: :grace_worker
  defp attempt_source(_attempt), do: :agent

  defp attempt_exit_code(%{"exit_code" => code}) when is_integer(code), do: code
  defp attempt_exit_code(_attempt), do: nil

  defp with_duration(measurements, %{"duration_ms" => ms}) when is_integer(ms) and ms >= 0,
    do: Map.put(measurements, :duration_ms, ms)

  defp with_duration(measurements, _attempt), do: measurements

  # The board id comes from the preloaded column when there is one, otherwise
  # from the task's column row. A failed lookup sends nil rather than raising
  # into the write that is being reported.
  defp board_id(%Task{column: %Column{board_id: board_id}}), do: board_id
  defp board_id(%Task{column_id: nil}), do: nil

  defp board_id(%Task{column_id: column_id}) do
    from(c in Column, where: c.id == ^column_id, select: c.board_id)
    |> Repo.one()
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> nil
  end
end
