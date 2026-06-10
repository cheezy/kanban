defmodule Kanban.Queries.BoardScopeTest do
  use Kanban.DataCase

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Queries.BoardScope
  alias Kanban.Repo
  alias Kanban.Tasks.Task

  setup do
    member = user_fixture()
    board = board_fixture(member)
    column = column_fixture(board)
    task = task_fixture(column, %{title: "Scoped task"})

    other_user = user_fixture()
    other_board = board_fixture(other_user)
    other_column = column_fixture(other_board)
    other_task = task_fixture(other_column, %{title: "Other board task"})

    %{
      member: member,
      task: task,
      other_user: other_user,
      other_task: other_task
    }
  end

  defp bound_query do
    from(t in Task, join: c in assoc(t, :column), as: :column)
  end

  defp ids(query), do: query |> Repo.all() |> Enum.map(& &1.id) |> Enum.sort()

  describe "apply_board_scope/2 (query with existing :column binding)" do
    test "a member sees only their boards' tasks", %{member: member, task: task} do
      result = bound_query() |> BoardScope.apply_board_scope(Scope.for_user(member)) |> ids()

      assert result == [task.id]
    end

    test "a user with no board memberships gets an empty result" do
      stranger = user_fixture()

      assert bound_query() |> BoardScope.apply_board_scope(Scope.for_user(stranger)) |> ids() ==
               []
    end

    test "a nil scope leaves the query unscoped", %{task: task, other_task: other_task} do
      result = bound_query() |> BoardScope.apply_board_scope(nil) |> ids()

      assert result == Enum.sort([task.id, other_task.id])
    end

    test "a scope without a user leaves the query unscoped", %{
      task: task,
      other_task: other_task
    } do
      result = bound_query() |> BoardScope.apply_board_scope(%Scope{user: nil}) |> ids()

      assert result == Enum.sort([task.id, other_task.id])
    end
  end

  describe "apply_board_scope_with_column_join/2 (bare task query)" do
    test "a member sees only their boards' tasks", %{member: member, task: task} do
      result =
        Task |> BoardScope.apply_board_scope_with_column_join(Scope.for_user(member)) |> ids()

      assert result == [task.id]
    end

    test "a user with no board memberships gets an empty result" do
      stranger = user_fixture()

      result =
        Task |> BoardScope.apply_board_scope_with_column_join(Scope.for_user(stranger)) |> ids()

      assert result == []
    end

    test "a nil scope leaves the bare query join-free and unscoped", %{
      task: task,
      other_task: other_task
    } do
      result = Task |> BoardScope.apply_board_scope_with_column_join(nil) |> ids()

      assert result == Enum.sort([task.id, other_task.id])
    end

    test "a scope without a user leaves the bare query unscoped", %{
      task: task,
      other_task: other_task
    } do
      result =
        Task |> BoardScope.apply_board_scope_with_column_join(%Scope{user: nil}) |> ids()

      assert result == Enum.sort([task.id, other_task.id])
    end
  end
end
