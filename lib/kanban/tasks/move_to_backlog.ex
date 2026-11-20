defmodule Kanban.Tasks.MoveToBacklog do
  @moduledoc """
  Moves one released or expired task back to Backlog, for the Now cards of
  the Stride app (W2760, docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md
  §6.1, §7.10). Called as `Kanban.Tasks.move_to_backlog/3`.

  An agent that releases a task (`Kanban.Tasks.unclaim_task/3`) leaves it
  open in Ready. Nothing releases an expired claim: the task stays
  `:in_progress` in Doing with its `claim_expires_at` in the past, and the
  claim queries treat it as claimable again. So those are the two places this
  moves from. The move goes through the one move path,
  `Kanban.Tasks.Positioning.move_task_unchecked/3`, to the end of Backlog, so
  the positions, the status, the move history and the parent goal's placement
  are written exactly as a drag on the web writes them. Moving an expired
  claim also clears it, as a release does: `claimed_at`, `claim_expires_at`
  and `assigned_to_id` are set to `nil`. It follows `Kanban.Tasks.Promote`,
  the app's move the other way.

  The guards run in order, and the first that fails decides the answer:

    1. **Write access.** The scope's user must hold `:owner` or `:modify`
       access on the board, re-read on every call (`{:error, :forbidden}`).
    2. **A Backlog column** on the board (`:no_backlog_column`).
    3. Inside a transaction, with every column of the board locked in one
       ascending pass (`Kanban.Tasks.ColumnLocks.lock_board_columns/1`) and
       the task read `FOR UPDATE`: the task must still be a live task on this
       board (`:not_found`), so one archived or deleted since the app read it
       is refused.
    4. It must be a work or defect task in Ready, or one in Doing whose claim
       has expired (`:not_movable`), so a task an agent claimed, or renewed
       its claim on, in the meantime stays in Doing. A task already in
       Backlog is left where it is and answered with `moved: false`, so a
       retry never moves a task twice.
    5. Backlog's WIP limit must hold it (`:backlog_wip_limit_reached`).

  A task moved by someone else in the middle of the move is `:conflict`, and
  any other failure of the write `:move_failed`; nothing is moved either way.

  Once it commits, the task is broadcast as `:task_moved` and emits
  `[:kanban, :task, :moved]`, as a move on the web does. Nothing is
  broadcast on failure or for a task already in Backlog.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Boards.Board
  alias Kanban.Columns
  alias Kanban.Columns.Column
  alias Kanban.Repo
  alias Kanban.Tasks.AppTasks
  alias Kanban.Tasks.Broadcaster
  alias Kanban.Tasks.ColumnLocks
  alias Kanban.Tasks.ColumnRenumbering
  alias Kanban.Tasks.Positioning
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskTelemetry

  @movable_types [:work, :defect]

  @type error ::
          :forbidden
          | :no_backlog_column
          | :not_found
          | :not_movable
          | :backlog_wip_limit_reached
          | :conflict
          | :move_failed

  @doc """
  Moves `task` on `board` to the end of the board's Backlog.

  Returns `{:ok, %{task: task, moved: true}}` with the moved task (its
  `:labels` loaded), `{:ok, %{task: task, moved: false}}` when the task was
  already in Backlog, or `{:error, reason}`; see the module doc for every
  reason.
  """
  @spec move(Scope.t() | nil, Board.t(), Task.t()) ::
          {:ok, %{task: Task.t(), moved: boolean()}} | {:error, error()}
  def move(scope, %Board{} = board, %Task{id: task_id}) do
    with :ok <- AppTasks.authorize_write(scope, board),
         {:ok, backlog} <- AppTasks.fetch_backlog(board) do
      fn -> move_locked(board, task_id, backlog) end
      |> Repo.transaction()
      |> after_commit(board)
    end
  end

  defp move_locked(board, task_id, backlog) do
    columns = ColumnLocks.lock_board_columns(board.id)

    with {:ok, task} <- fetch_locked(columns, task_id),
         {:ok, plan} <- classify(task, columns, backlog, DateTime.utc_now(:second)) do
      run(plan, task, backlog)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp fetch_locked(columns, task_id) do
    column_ids = Enum.map(columns, & &1.id)

    from(t in Task,
      where: t.id == ^task_id and is_nil(t.archived_at) and t.column_id in ^column_ids,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
    |> case do
      %Task{} = task -> {:ok, task}
      nil -> {:error, :not_found}
    end
  end

  defp classify(%Task{type: type}, _columns, _backlog, _now) when type not in @movable_types,
    do: {:error, :not_movable}

  defp classify(%Task{column_id: backlog_id}, _columns, %Column{id: backlog_id}, _now),
    do: {:ok, :already_in_backlog}

  defp classify(%Task{column_id: column_id} = task, columns, _backlog, now) do
    column = Enum.find(columns, &(&1.id == column_id))

    cond do
      Columns.named?(column, "Ready") -> {:ok, :move}
      Columns.named?(column, "Doing") and expired_claim?(task, now) -> {:ok, :release}
      true -> {:error, :not_movable}
    end
  end

  # The claim queries' own test for an expired claim (`Kanban.Tasks.AgentQueries`).
  defp expired_claim?(%Task{status: :in_progress, claim_expires_at: %DateTime{} = at}, now),
    do: DateTime.before?(at, now)

  defp expired_claim?(_task, _now), do: false

  defp run(:already_in_backlog, task, _backlog), do: {:unchanged, task}

  defp run(plan, task, backlog) do
    with :ok <- check_wip(backlog),
         {:ok, moved} <-
           Positioning.move_task_unchecked(task, backlog, ColumnRenumbering.live_count(backlog)) do
      {:moved, release(plan, moved), task.column_id}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp release(:move, task), do: task

  defp release(:release, %Task{id: id} = task) do
    cleared = [claimed_at: nil, claim_expires_at: nil, assigned_to_id: nil]
    {1, _} = from(t in Task, where: t.id == ^id) |> Repo.update_all(set: cleared)
    struct(task, [{:assigned_to, nil} | cleared])
  end

  defp check_wip(%Column{wip_limit: limit} = backlog) when limit > 0 do
    if Positioning.wip_count(backlog) >= limit,
      do: {:error, :backlog_wip_limit_reached},
      else: :ok
  end

  defp check_wip(_backlog), do: :ok

  defp after_commit({:ok, {:moved, task, from_column_id}}, board) do
    Broadcaster.broadcast_task_change(task, :task_moved)
    TaskTelemetry.moved(task, from_column_id, board.id)
    {:ok, %{task: Repo.preload(task, :labels), moved: true}}
  end

  defp after_commit({:ok, {:unchanged, task}}, _board),
    do: {:ok, %{task: Repo.preload(task, :labels), moved: false}}

  defp after_commit({:error, reason}, _board) when is_atom(reason), do: {:error, reason}
  defp after_commit({:error, _reason}, _board), do: {:error, :move_failed}
end
