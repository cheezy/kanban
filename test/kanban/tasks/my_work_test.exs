defmodule Kanban.Tasks.MyWorkTest do
  @moduledoc """
  Tests for `Kanban.Tasks.MyWork` — the cross-board My Work queue (W2237).
  """
  use Kanban.DataCase, async: true

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.LabelsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Labels
  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.MyWork
  alias Kanban.Tasks.Task

  setup do
    user = user_fixture()
    scope = Scope.for_user(user)
    board = board_fixture(user, %{name: "Alpha board"})
    column = column_fixture(board)
    %{user: user, scope: scope, board: board, column: column}
  end

  defp assigned_task(column, user, attrs \\ %{}) do
    task_fixture(column, Map.put(attrs, :assigned_to_id, user.id))
  end

  defp ids(tasks), do: Enum.map(tasks, & &1.id)

  describe "list_assigned_tasks/2" do
    test "returns the user's assigned tasks across boards with column.board and labels preloaded",
         %{user: user, scope: scope, board: board, column: column} do
      other_board = board_fixture(user, %{name: "Beta board"})
      other_column = column_fixture(other_board)

      task_a = assigned_task(column, user)
      task_b = assigned_task(other_column, user)

      label = label_fixture(board, %{name: "backend"})
      {:ok, _} = Labels.set_task_labels(scope, task_a, [label.id])

      [first, second] = MyWork.list_assigned_tasks(scope)

      assert first.id == task_a.id
      assert second.id == task_b.id
      assert first.column.board.id == board.id
      assert second.column.board.id == other_board.id
      assert Enum.map(first.labels, & &1.name) == ["backend"]
      assert second.labels == []
    end

    test "excludes other users' tasks and unassigned tasks", %{
      user: user,
      scope: scope,
      board: board,
      column: column
    } do
      other_user = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, other_user, :modify, user)

      mine = assigned_task(column, user)
      _theirs = assigned_task(column, other_user)
      _unassigned = task_fixture(column)

      assert ids(MyWork.list_assigned_tasks(scope)) == [mine.id]
    end

    test "excludes archived tasks", %{user: user, scope: scope, column: column} do
      kept = assigned_task(column, user)
      archived = assigned_task(column, user)
      {:ok, _} = Tasks.archive_task(archived)

      assert ids(MyWork.list_assigned_tasks(scope)) == [kept.id]
    end

    test "excludes completed tasks but keeps open, in-progress and blocked ones", %{
      user: user,
      scope: scope,
      column: column
    } do
      open = assigned_task(column, user)
      in_progress = assigned_task(column, user)
      blocked = assigned_task(column, user)
      completed = assigned_task(column, user)

      set_status(in_progress, :in_progress)
      set_status(blocked, :blocked)
      set_status(completed, :completed)

      listed = scope |> MyWork.list_assigned_tasks() |> ids() |> MapSet.new()
      assert listed == MapSet.new([open.id, in_progress.id, blocked.id])
    end

    test "excludes a blocked task moved into a Done column", %{
      user: user,
      scope: scope,
      board: board,
      column: column
    } do
      done = column_fixture(board, %{name: "Done"})
      kept = assigned_task(column, user)
      blocked = assigned_task(column, user)
      set_status(blocked, :blocked)

      {:ok, moved} = Task |> Repo.get!(blocked.id) |> Tasks.move_task(done, 0)
      assert moved.status == :blocked

      assert ids(MyWork.list_assigned_tasks(scope)) == [kept.id]
    end

    test "matches a Done column name with surrounding tabs or newlines", %{
      user: user,
      scope: scope,
      board: board
    } do
      done = column_fixture(board, %{name: "\tDone\n"})
      task = assigned_task(done, user)
      set_status(task, :blocked)

      assert MyWork.list_assigned_tasks(scope) == []
    end

    test "matches the Done column name ignoring case and surrounding spaces", %{
      user: user,
      scope: scope,
      board: board
    } do
      done = column_fixture(board, %{name: "  dONE "})
      task = assigned_task(done, user)
      set_status(task, :blocked)

      assert MyWork.list_assigned_tasks(scope) == []
    end

    test "includes goal-type tasks assigned to the user", %{
      user: user,
      scope: scope,
      column: column
    } do
      goal = assigned_task(column, user, %{type: :goal})

      assert [%Task{id: id, type: :goal}] = MyWork.list_assigned_tasks(scope)
      assert id == goal.id
    end

    test "drops a board's tasks once the user is removed from that board", %{user: owner} do
      member = user_fixture()
      member_scope = Scope.for_user(member)
      board = board_fixture(owner)
      column = column_fixture(board)
      {:ok, _} = Boards.add_user_to_board(board, member, :modify, owner)

      task = assigned_task(column, member)
      assert ids(MyWork.list_assigned_tasks(member_scope)) == [task.id]

      {:ok, _} = Boards.remove_user_from_board(board, member, owner)
      assert MyWork.list_assigned_tasks(member_scope) == []
    end

    test "records the user's membership access on each task's board", %{user: owner} do
      member = user_fixture()
      modify_board = board_fixture(owner, %{name: "Alpha modify"})
      read_board = board_fixture(owner, %{name: "Beta read"})
      {:ok, _} = Boards.add_user_to_board(modify_board, member, :modify, owner)
      {:ok, _} = Boards.add_user_to_board(read_board, member, :read_only, owner)
      assigned_task(column_fixture(modify_board), member)
      assigned_task(column_fixture(read_board), member)
      own_board = board_fixture(member, %{name: "Gamma own"})
      assigned_task(column_fixture(own_board), member)

      accesses =
        member
        |> Scope.for_user()
        |> MyWork.list_assigned_tasks()
        |> Enum.map(&{&1.column.board.id, &1.column.board.user_access})

      assert accesses == [
               {modify_board.id, :modify},
               {read_board.id, :read_only},
               {own_board.id, :owner}
             ]
    end

    test "excludes tasks on a public read-only board the user is not a member of", %{
      user: owner,
      board: board,
      column: column
    } do
      Board
      |> where([b], b.id == ^board.id)
      |> Repo.update_all(set: [read_only: true])

      outsider = user_fixture()
      _stale = assigned_task(column, outsider)

      assert outsider |> Scope.for_user() |> MyWork.list_assigned_tasks() == []
      assert owner |> Scope.for_user() |> MyWork.list_assigned_tasks() == []
    end

    test "orders by board name, then priority from critical to low", %{
      user: user,
      scope: scope,
      column: column
    } do
      zeta = board_fixture(user, %{name: "Zeta board"})
      zeta_column = column_fixture(zeta)
      zeta_task = assigned_task(zeta_column, user, %{priority: :critical})

      low = assigned_task(column, user, %{priority: :low})
      critical = assigned_task(column, user, %{priority: :critical})
      medium = assigned_task(column, user, %{priority: :medium})
      high = assigned_task(column, user, %{priority: :high})

      assert ids(MyWork.list_assigned_tasks(scope)) ==
               [critical.id, high.id, medium.id, low.id, zeta_task.id]
    end

    test "returns [] for a nil scope or a scope without a user", %{
      user: user,
      column: column
    } do
      _task = assigned_task(column, user)

      assert MyWork.list_assigned_tasks(nil) == []
      assert MyWork.list_assigned_tasks(%Scope{user: nil}) == []
    end

    test "respects the :limit option", %{user: user, scope: scope, column: column} do
      for _ <- 1..3, do: assigned_task(column, user)

      assert length(MyWork.list_assigned_tasks(scope, limit: 2)) == 2
      assert length(MyWork.list_assigned_tasks(scope, limit: nil)) == 3
    end

    test "is reachable through the Kanban.Tasks facade", %{
      user: user,
      scope: scope,
      column: column
    } do
      task = assigned_task(column, user)

      assert ids(Tasks.list_assigned_tasks(scope)) == [task.id]
    end
  end

  describe "group_by_board/1" do
    test "returns [] for no tasks" do
      assert MyWork.group_by_board([]) == []
      assert Tasks.group_tasks_by_board([]) == []
    end

    test "groups tasks into {board, tasks} tuples in query order", %{
      user: user,
      scope: scope,
      board: board,
      column: column
    } do
      beta = board_fixture(user, %{name: "Beta board"})
      beta_column = column_fixture(beta)

      a1 = assigned_task(column, user, %{priority: :high})
      a2 = assigned_task(column, user, %{priority: :low})
      b1 = assigned_task(beta_column, user)

      groups = scope |> MyWork.list_assigned_tasks() |> MyWork.group_by_board()

      assert [{%Board{id: board_a}, tasks_a}, {%Board{id: board_b}, tasks_b}] = groups
      assert board_a == board.id
      assert board_b == beta.id
      assert ids(tasks_a) == [a1.id, a2.id]
      assert ids(tasks_b) == [b1.id]
    end
  end

  defp set_status(task, status) do
    Task
    |> where([t], t.id == ^task.id)
    |> Repo.update_all(set: [status: status])
  end
end
