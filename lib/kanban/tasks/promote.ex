defmodule Kanban.Tasks.Promote do
  @moduledoc """
  Promotes several Backlog tasks of one board to Ready in one transaction,
  for the app's Boards tab (W2759, docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md
  §6.9, §7.10). Called as `Kanban.Tasks.promote_to_ready/4`.

  It follows the web's Backlog arrow (`KanbanWeb.BoardLive.TaskActions`): only
  a work or defect task in a column named Backlog moves, to the end of the
  board's Ready column. Every move goes through the one move path,
  `Kanban.Tasks.Positioning.move_task_unchecked/3`, so the positions, the
  status, the move history and the parent goal's placement are written exactly
  as a drag on the web writes them.

  The guards run in order, and the first that fails decides the answer:

    1. **Write access.** The scope's user must hold `:owner` or `:modify`
       access on the board, re-read on every call (`{:error, :forbidden}`).
    2. **A selection** of 1 to 100 positive integer ids (`:empty_selection`,
       `:too_many_tasks`; a malformed id is `:not_found`).
    3. **A Ready column** on the board (`:no_ready_column`).
    4. Inside the transaction, with every column of the board locked in one
       ascending pass (`Kanban.Tasks.ColumnLocks.lock_board_columns/1`) and the
       tasks read `FOR UPDATE`: every id must name a live task in one of this
       board's columns (`:not_found`), so a task from another board, or one
       archived since the app read it, refuses the whole promote.
    5. Every task must be a work or defect task in Backlog, or one already in
       Ready (`{:not_promotable, ids}`, with the ids that are neither); a goal
       refuses wherever it sits, Ready included.
    6. The Ready column's WIP limit must hold the moved tasks
       (`:wip_limit_reached`).

  A task already in Ready is left where it is and reported in
  `already_ready`, so a retry, or two promotes of the same task, never move a
  task twice. `needs_review: true` sets `needs_review` on every moved task;
  `false` or absent leaves it as it is. Nothing else about a task is written:
  edits beyond `needs_review` stay on the web.

  It succeeds or fails as a whole. Once it commits, each moved task is
  broadcast as `:task_moved` and emits `[:kanban, :task, :moved]`, as a move on
  the web does, so an open board updates card by card. Nothing is broadcast on
  failure.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Columns
  alias Kanban.Columns.Column
  alias Kanban.Repo
  alias Kanban.Tasks.Broadcaster
  alias Kanban.Tasks.ColumnLocks
  alias Kanban.Tasks.ColumnRenumbering
  alias Kanban.Tasks.Positioning
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskTelemetry

  @max_tasks 100
  @max_bigint 9_223_372_036_854_775_807
  @promotable_types [:work, :defect]

  @type error ::
          :forbidden
          | :empty_selection
          | :too_many_tasks
          | :not_found
          | :no_ready_column
          | :wip_limit_reached
          | :conflict
          | :update_failed
          | {:not_promotable, [pos_integer()]}

  @type result ::
          {:ok, %{promoted: [Task.t()], already_ready: [pos_integer()]}} | {:error, error()}

  @doc "The most task ids one promote takes."
  def max_tasks, do: @max_tasks

  @doc """
  Moves the Backlog tasks `task_ids` of `board` to the end of its Ready
  column, in their Backlog order. Options: `needs_review: true` sets
  `needs_review` on each moved task.

  Returns `{:ok, %{promoted: tasks, already_ready: ids}}`, where `promoted`
  holds the moved tasks (with their labels) in their new order, or
  `{:error, reason}`; see the module doc for every reason.
  """
  @spec promote(Scope.t() | nil, Board.t(), term(), keyword()) :: result()
  def promote(scope, %Board{} = board, task_ids, opts \\ []) do
    with :ok <- authorize(scope, board),
         {:ok, ids} <- normalize_ids(task_ids),
         {:ok, ready} <- fetch_ready(board) do
      board
      |> promote_multi(ids, ready, Keyword.get(opts, :needs_review) == true)
      |> Repo.transaction()
      |> after_commit(board)
    end
  end

  defp authorize(%Scope{user: %{id: user_id}}, %Board{id: board_id}) do
    if Boards.get_user_access(board_id, user_id) in [:owner, :modify],
      do: :ok,
      else: {:error, :forbidden}
  end

  defp authorize(_scope, _board), do: {:error, :forbidden}

  defp normalize_ids([]), do: {:error, :empty_selection}

  defp normalize_ids(ids) when is_list(ids) do
    unique = Enum.uniq(ids)

    cond do
      not Enum.all?(unique, &valid_id?/1) -> {:error, :not_found}
      length(unique) > @max_tasks -> {:error, :too_many_tasks}
      true -> {:ok, unique}
    end
  end

  defp normalize_ids(_ids), do: {:error, :not_found}

  defp valid_id?(id), do: is_integer(id) and id > 0 and id <= @max_bigint

  defp fetch_ready(%Board{id: board_id}) do
    case Columns.get_column_by_name(board_id, "Ready") do
      %Column{} = ready -> {:ok, ready}
      nil -> {:error, :no_ready_column}
    end
  end

  defp promote_multi(board, ids, ready, needs_review?) do
    Multi.new()
    |> read_locked(board, ids, ready)
    |> write_moves(ready, needs_review?)
  end

  # Locks the board's columns, reads the tasks under them and sorts them.
  defp read_locked(multi, board, ids, ready) do
    multi
    |> Multi.run(:columns, fn _repo, _ -> {:ok, ColumnLocks.lock_board_columns(board.id)} end)
    |> Multi.run(:tasks, fn _repo, %{columns: columns} -> fetch_tasks(columns, ids) end)
    |> Multi.run(:split, fn _repo, changes -> split(changes, ready) end)
  end

  defp write_moves(multi, ready, needs_review?) do
    multi
    |> Multi.run(:wip, fn _repo, %{split: split} -> check_wip(split.movable, ready) end)
    |> Multi.run(:needs_review, fn _repo, %{split: split} ->
      set_needs_review(split.movable, needs_review?)
    end)
    |> Multi.run(:moved, fn _repo, %{split: split} -> move_all(split.movable, ready) end)
  end

  # Reads the selected live tasks through the board's own columns, locked in
  # id order, and fails unless every id was found.
  defp fetch_tasks(columns, ids) do
    column_ids = Enum.map(columns, & &1.id)

    tasks =
      from(t in Task,
        where: t.id in ^ids and is_nil(t.archived_at) and t.column_id in ^column_ids,
        order_by: t.id,
        lock: "FOR UPDATE"
      )
      |> Repo.all()

    if length(tasks) == length(ids), do: {:ok, tasks}, else: {:error, :not_found}
  end

  defp split(%{columns: columns, tasks: tasks}, %Column{} = ready) do
    groups = group(tasks, columns, ready)

    case Map.get(groups, :refused, []) do
      [] -> {:ok, split_result(groups)}
      refused -> {:error, {:not_promotable, Enum.map(refused, & &1.id)}}
    end
  end

  defp group(tasks, columns, ready) do
    columns_by_id = Map.new(columns, &{&1.id, &1})
    Enum.group_by(tasks, &classify(&1, columns_by_id, ready))
  end

  # A goal refuses wherever it sits, Ready included.
  defp classify(%Task{type: type}, _columns_by_id, _ready) when type not in @promotable_types,
    do: :refused

  defp classify(%Task{column_id: ready_id}, _columns_by_id, %Column{id: ready_id}),
    do: :already_ready

  defp classify(%Task{column_id: column_id}, columns_by_id, _ready) do
    if columns_by_id |> Map.fetch!(column_id) |> Columns.named?("Backlog"),
      do: :movable,
      else: :refused
  end

  defp split_result(groups) do
    movable = groups |> Map.get(:movable, []) |> Enum.sort_by(&{&1.position, &1.id})
    already_ready = groups |> Map.get(:already_ready, []) |> Enum.map(& &1.id)
    %{movable: movable, already_ready: already_ready}
  end

  defp check_wip([], _ready), do: {:ok, 0}
  defp check_wip(_movable, %Column{wip_limit: limit}) when limit <= 0, do: {:ok, 0}

  defp check_wip(movable, %Column{wip_limit: limit} = ready) do
    if Positioning.wip_count(ready) + length(movable) > limit,
      do: {:error, :wip_limit_reached},
      else: {:ok, length(movable)}
  end

  # Before the moves, so each move's re-read of the task carries the flag.
  defp set_needs_review(movable, true) when movable != [] do
    ids = Enum.map(movable, & &1.id)

    {count, _} =
      from(t in Task, where: t.id in ^ids and t.needs_review == false)
      |> Repo.update_all(set: [needs_review: true, updated_at: DateTime.utc_now(:second)])

    {:ok, count}
  end

  defp set_needs_review(_movable, _needs_review?), do: {:ok, 0}

  # Each move re-reads its task under the column locks and appends it to
  # Ready, so the tasks land in the order given; the first error rolls back
  # every move already made.
  defp move_all(movable, ready) do
    movable
    |> Enum.reduce_while({:ok, []}, fn task, {:ok, acc} ->
      case Positioning.move_task_unchecked(task, ready, ColumnRenumbering.live_count(ready)) do
        {:ok, moved} -> {:cont, {:ok, [{moved, task.column_id} | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, moved} -> {:ok, Enum.reverse(moved)}
      error -> error
    end
  end

  defp after_commit({:ok, %{moved: moved, split: split}}, board) do
    Enum.each(moved, fn {task, from_column_id} ->
      Broadcaster.broadcast_task_change(task, :task_moved)
      TaskTelemetry.moved(task, from_column_id, board.id)
    end)

    promoted = moved |> Enum.map(&elem(&1, 0)) |> Repo.preload(:labels)
    {:ok, %{promoted: promoted, already_ready: split.already_ready}}
  end

  defp after_commit({:error, _step, {:not_promotable, _ids} = reason, _changes}, _board),
    do: {:error, reason}

  defp after_commit({:error, _step, reason, _changes}, _board) when is_atom(reason),
    do: {:error, reason}

  defp after_commit({:error, _step, _reason, _changes}, _board), do: {:error, :update_failed}
end
