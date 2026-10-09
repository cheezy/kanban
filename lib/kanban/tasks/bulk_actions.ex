defmodule Kanban.Tasks.BulkActions do
  @moduledoc """
  Bulk move, assign, label and archive for the tasks selected on a board.

  Every function takes the caller's `%Kanban.Accounts.Scope{}` and the board
  first, then the selected task ids, then the action's target. Each runs the
  same guards, in order, before anything is written:

    1. **Authorization.** The scope's user must hold `:owner` or `:modify`
       access on the board, re-read from the database on every call so a
       hidden control or a stale socket is never the only check
       (`{:error, :unauthorized}`).
    2. **A non-empty selection of integer ids** (`{:error, :empty_selection}`;
       a malformed id is `{:error, :not_found}`).
    3. **A board-scoped target**: the column (`:invalid_column`), the
       assignee — any member of the board (`:invalid_assignee`) — or the label
       (`:invalid_label`).
    4. **Board-scoped tasks.** Inside the transaction (after a move has locked
       the board's columns), every id must name a live (unarchived) task in one
       of this board's columns, and the number of tasks found must equal the
       number of distinct ids. A foreign, archived or deleted id aborts the
       whole action (`{:error, :not_found}`).

  The first failing guard decides the error, so a selection holding a foreign
  task id sent with an invalid target reports the target error.

  The writes then run in one `Ecto.Multi`, so an action succeeds or fails as
  a whole. When it changed anything, exactly one `:task_updated` broadcast is
  sent on the board's topic after the transaction commits — never one per
  task. Nothing is broadcast on failure, or when the action committed but
  changed nothing (an all-goal selection, a no-op assign, a label every task
  already had). A move whose work and defect tasks would push the target column
  past its WIP limit changes nothing (`{:error, :wip_limit_reached}`), and a
  failed write rolls the whole action back (`{:error, :update_failed}`).

  Goals are skipped by move, assign and archive: a goal's position is derived
  from its children, and assigning or archiving one cascades to them, which a
  bulk action over a mixed selection must not do silently. They are counted
  in `:skipped_goals` so the board can say so. Labels apply to goals too.

  Success is `{:ok, %{count: changed, skipped_goals: goals}}`, where `count`
  is the number of tasks (for labels: label rows) actually changed.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Columns
  alias Kanban.Columns.Column
  alias Kanban.Labels.Label
  alias Kanban.Labels.TaskLabel
  alias Kanban.Notifications.Events
  alias Kanban.Repo
  alias Kanban.Tasks.Broadcaster
  alias Kanban.Tasks.Positioning
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskHistory

  @type result ::
          {:ok, %{count: non_neg_integer(), skipped_goals: non_neg_integer()}}
          | {:error, atom()}

  @doc """
  Moves the selected tasks to the end of `column_id`, in their current board
  order (column, then position). Tasks already in that column are left where
  they are; goals are skipped.
  """
  @spec move(Scope.t() | nil, Board.t(), list(), term()) :: result()
  def move(scope, %Board{} = board, task_ids, column_id) do
    with {:ok, _user, ids} <- prepare(scope, board, task_ids),
         {:ok, column} <- fetch_column(board, column_id) do
      board |> move_multi(ids, column) |> commit()
    end
  end

  @doc """
  Assigns the selected tasks to `assignee_id` (a member of the board), or
  unassigns them when it is `nil`. Records assignment history for each task
  whose assignee changes and notifies the assignee once the write commits;
  goals are skipped.
  """
  @spec assign(Scope.t() | nil, Board.t(), list(), integer() | nil) :: result()
  def assign(scope, %Board{} = board, task_ids, assignee_id) do
    with {:ok, user, ids} <- prepare(scope, board, task_ids),
         :ok <- validate_assignee(board, assignee_id) do
      board |> assign_multi(ids, assignee_id) |> commit(&notify_assigned(&1, user))
    end
  end

  @doc "Adds the board label `label_id` to the selected tasks, keeping their other labels."
  @spec add_label(Scope.t() | nil, Board.t(), list(), term()) :: result()
  def add_label(scope, %Board{} = board, task_ids, label_id) do
    with {:ok, _user, ids} <- prepare(scope, board, task_ids),
         {:ok, label} <- fetch_label(board, label_id) do
      board |> tasks_multi(ids, &insert_labels(&1, &2, label)) |> commit()
    end
  end

  @doc "Removes the board label `label_id` from the selected tasks only."
  @spec remove_label(Scope.t() | nil, Board.t(), list(), term()) :: result()
  def remove_label(scope, %Board{} = board, task_ids, label_id) do
    with {:ok, _user, ids} <- prepare(scope, board, task_ids),
         {:ok, label} <- fetch_label(board, label_id) do
      board |> tasks_multi(ids, &delete_labels(&1, &2, label)) |> commit()
    end
  end

  @doc """
  Archives the selected tasks, recording the same fields as archiving one
  task from the board (`archived_at` only) and emitting the same
  `[:kanban, :task, :archived]` telemetry per task, tagged `via: :bulk`.
  Goals are skipped.
  """
  @spec archive(Scope.t() | nil, Board.t(), list()) :: result()
  def archive(scope, %Board{} = board, task_ids) do
    with {:ok, _user, ids} <- prepare(scope, board, task_ids) do
      board |> tasks_multi(ids, &archive_all/2) |> commit(&emit_archive_telemetry/1)
    end
  end

  # ── Multis ─────────────────────────────────────────────────────────

  defp move_multi(board, ids, column) do
    Multi.new()
    |> Multi.run(:columns, fn repo, _ -> lock_board_columns(repo, board) end)
    |> Multi.run(:tasks, fn repo, _ -> fetch_tasks(repo, board, ids, false) end)
    |> Multi.run(:movable, fn _repo, %{tasks: tasks} -> check_wip(tasks, column) end)
    |> Multi.run(:summary, fn repo, changes -> move_all(repo, changes, column) end)
  end

  defp assign_multi(board, ids, assignee_id),
    do: tasks_multi(board, ids, &assign_all(&1, &2, assignee_id))

  # Locks the selected task rows, then runs `apply_fun.(repo, tasks)` as the
  # action's `:summary` step.
  defp tasks_multi(board, ids, apply_fun) do
    Multi.new()
    |> Multi.run(:tasks, fn repo, _ -> fetch_tasks(repo, board, ids, true) end)
    |> Multi.run(:summary, fn repo, %{tasks: tasks} -> apply_fun.(repo, tasks) end)
  end

  # ── Guards ─────────────────────────────────────────────────────────

  # Guards 1 and 2: authorization, then a well-formed, non-empty selection.
  defp prepare(scope, board, task_ids) do
    with {:ok, user} <- authorize(scope, board),
         {:ok, ids} <- normalize_ids(task_ids) do
      {:ok, user, ids}
    end
  end

  defp authorize(%Scope{user: %{id: user_id} = user}, %Board{id: board_id}) do
    if Boards.get_user_access(board_id, user_id) in [:owner, :modify],
      do: {:ok, user},
      else: {:error, :unauthorized}
  end

  defp authorize(_scope, _board), do: {:error, :unauthorized}

  defp normalize_ids([]), do: {:error, :empty_selection}

  defp normalize_ids(ids) when is_list(ids) do
    if Enum.all?(ids, &is_integer/1),
      do: {:ok, Enum.uniq(ids)},
      else: {:error, :not_found}
  end

  defp normalize_ids(_ids), do: {:error, :not_found}

  defp fetch_column(%Board{id: board_id}, column_id) when is_integer(column_id) do
    case Columns.get_column_for_board(column_id, board_id) do
      %Column{} = column -> {:ok, column}
      nil -> {:error, :invalid_column}
    end
  end

  defp fetch_column(_board, _column_id), do: {:error, :invalid_column}

  defp fetch_label(%Board{id: board_id}, label_id) when is_integer(label_id) do
    case Repo.get_by(Label, id: label_id, board_id: board_id) do
      %Label{} = label -> {:ok, label}
      nil -> {:error, :invalid_label}
    end
  end

  defp fetch_label(_board, _label_id), do: {:error, :invalid_label}

  defp validate_assignee(_board, nil), do: :ok

  defp validate_assignee(%Board{id: board_id}, user_id) when is_integer(user_id) do
    member_query =
      from(bu in BoardUser, where: bu.board_id == ^board_id and bu.user_id == ^user_id)

    if Repo.exists?(member_query), do: :ok, else: {:error, :invalid_assignee}
  end

  defp validate_assignee(_board, _user_id), do: {:error, :invalid_assignee}

  # Loads the selected live tasks through the board's own columns and fails
  # unless every id was found. `lock?` takes the task rows FOR UPDATE (in id
  # order) so a concurrent single-task edit cannot interleave with the batch.
  defp fetch_tasks(repo, %Board{id: board_id}, ids, lock?) do
    board_columns = from(c in Column, where: c.board_id == ^board_id, select: c.id)

    query =
      from(t in Task,
        where: t.id in ^ids and is_nil(t.archived_at),
        where: t.column_id in subquery(board_columns),
        order_by: t.id
      )

    tasks = query |> maybe_lock(lock?) |> repo.all()

    if length(tasks) == length(ids),
      do: {:ok, tasks},
      else: {:error, :not_found}
  end

  defp maybe_lock(query, true), do: lock(query, "FOR UPDATE")
  defp maybe_lock(query, false), do: query

  # ── Move ───────────────────────────────────────────────────────────

  # Every column of the board, locked in ascending id order — the order
  # Positioning's single move uses — so the batch cannot deadlock against a
  # concurrent drag, whichever columns that drag touches.
  defp lock_board_columns(repo, %Board{id: board_id}) do
    columns =
      from(c in Column, where: c.board_id == ^board_id, order_by: c.id)
      |> repo.all()

    Enum.each(columns, fn column ->
      repo.query!("SELECT pg_advisory_xact_lock($1)", [column.id])
    end)

    {:ok, columns}
  end

  defp check_wip(tasks, %Column{} = column) do
    movable = Enum.reject(tasks, &(goal?(&1) or &1.column_id == column.id))
    incoming = Enum.count(movable, &(&1.type in [:work, :defect]))

    if exceeds_wip?(column, incoming),
      do: {:error, :wip_limit_reached},
      else: {:ok, movable}
  end

  defp exceeds_wip?(_column, 0), do: false
  defp exceeds_wip?(%Column{wip_limit: limit}, _incoming) when limit <= 0, do: false

  defp exceeds_wip?(%Column{wip_limit: limit} = column, incoming),
    do: Positioning.wip_count(column) + incoming > limit

  defp move_all(repo, %{columns: columns, tasks: tasks, movable: movable}, column) do
    # An earlier move in this batch may have renumbered a task's source
    # column; move_task_unchecked re-reads the task under the column locks, so
    # the gap it leaves is closed from its current position.
    movable
    |> in_board_order(columns)
    |> update_each(&Positioning.move_task_unchecked(&1, column, live_count(repo, column)))
    |> to_summary(tasks)
  end

  # Column position, then task position, then id.
  defp in_board_order(tasks, columns) do
    column_order = Map.new(columns, &{&1.id, &1.position})
    Enum.sort_by(tasks, &{Map.get(column_order, &1.column_id), &1.position, &1.id})
  end

  defp live_count(repo, %Column{id: column_id}) do
    from(t in Task,
      where: t.column_id == ^column_id and is_nil(t.archived_at) and t.position >= 0
    )
    |> repo.aggregate(:count)
  end

  # ── Assign ─────────────────────────────────────────────────────────

  defp assign_all(repo, tasks, assignee_id) do
    tasks
    |> Enum.reject(&(goal?(&1) or &1.assigned_to_id == assignee_id))
    |> update_each(fn task ->
      with {:ok, updated} <-
             task |> Task.changeset(%{assigned_to_id: assignee_id}) |> repo.update(),
           {:ok, _history} <- task |> assignment_history(assignee_id) |> repo.insert() do
        {:ok, updated}
      end
    end)
    |> to_summary(tasks)
  end

  defp assignment_history(%Task{} = task, assignee_id) do
    TaskHistory.changeset(%TaskHistory{}, %{
      task_id: task.id,
      type: :assignment,
      from_user_id: task.assigned_to_id,
      to_user_id: assignee_id
    })
  end

  # ── Labels ─────────────────────────────────────────────────────────

  defp insert_labels(repo, tasks, %Label{id: label_id}) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      Enum.map(tasks, fn task ->
        %{task_id: task.id, label_id: label_id, inserted_at: now, updated_at: now}
      end)

    {count, _} =
      repo.insert_all(TaskLabel, rows,
        on_conflict: :nothing,
        conflict_target: [:task_id, :label_id]
      )

    {:ok, label_summary(count, tasks)}
  end

  defp delete_labels(repo, tasks, %Label{id: label_id}) do
    task_ids = Enum.map(tasks, & &1.id)

    {count, _} =
      from(tl in TaskLabel, where: tl.task_id in ^task_ids and tl.label_id == ^label_id)
      |> repo.delete_all()

    {:ok, label_summary(count, tasks)}
  end

  defp label_summary(count, tasks) do
    %{count: count, skipped_goals: 0, changed: [], broadcast: count > 0 && List.first(tasks)}
  end

  # ── Archive ────────────────────────────────────────────────────────

  defp archive_all(repo, tasks) do
    archived_at = DateTime.utc_now() |> DateTime.truncate(:second)

    tasks
    |> Enum.reject(&goal?/1)
    |> update_each(fn task ->
      task |> Task.archive_changeset(%{archived_at: archived_at}) |> repo.update()
    end)
    |> to_summary(tasks)
  end

  defp notify_assigned(summary, user),
    do: Enum.each(summary.changed, &Events.task_assigned(&1, user))

  defp emit_archive_telemetry(summary), do: Enum.each(summary.changed, &archive_event/1)

  defp archive_event(%Task{} = task) do
    :telemetry.execute(
      [:kanban, :task, :archived],
      %{task_id: task.id},
      %{identifier: task.identifier, via: :bulk}
    )
  end

  # ── Shared ─────────────────────────────────────────────────────────

  defp goal?(%Task{type: type}), do: type == :goal

  # Applies `fun` to each task in turn, halting on the first error so the
  # Multi rolls back everything already written.
  defp update_each(tasks, fun) do
    tasks
    |> Enum.reduce_while({:ok, []}, fn task, {:ok, acc} ->
      case fun.(task) do
        {:ok, updated} -> {:cont, {:ok, [updated | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, changed} -> {:ok, Enum.reverse(changed)}
      error -> error
    end
  end

  defp to_summary({:ok, changed}, tasks) do
    {:ok,
     %{
       count: length(changed),
       skipped_goals: Enum.count(tasks, &goal?/1),
       changed: changed,
       broadcast: List.last(changed)
     }}
  end

  defp to_summary(error, _tasks), do: error

  defp commit(multi, after_commit \\ fn _summary -> :ok end) do
    case Repo.transaction(multi) do
      {:ok, %{summary: summary}} ->
        after_commit.(summary)
        broadcast_once(summary.broadcast)
        {:ok, Map.take(summary, [:count, :skipped_goals])}

      {:error, _step, reason, _changes} when is_atom(reason) ->
        {:error, reason}

      {:error, _step, _reason, _changes} ->
        {:error, :update_failed}
    end
  end

  # One refresh for the whole action: every open board reloads on
  # `:task_updated`, so a single event re-renders all the changed cards.
  defp broadcast_once(%Task{} = task), do: Broadcaster.broadcast_task_change(task, :task_updated)
  defp broadcast_once(_none), do: :ok
end
