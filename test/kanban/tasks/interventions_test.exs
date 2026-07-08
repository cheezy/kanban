defmodule Kanban.Tasks.InterventionsTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TargetsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Targets
  alias Kanban.Tasks.Interventions

  describe "can_intervene?/2" do
    setup do
      board_owner = user_fixture()
      board = board_fixture(board_owner)
      column = column_fixture(board)

      %{board_owner: board_owner, board: board, column: column}
    end

    test "returns true for the board owner of the goal's board", %{
      board_owner: board_owner,
      column: column
    } do
      goal = task_fixture(column, %{type: :goal})
      scope = Scope.for_user(board_owner)

      assert Interventions.can_intervene?(scope, goal)
    end

    test "returns true for the goal's delivery-target owner who is a board member",
         %{board_owner: board_owner, board: board, column: column} do
      target_owner = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, target_owner, :read_only, board_owner)
      target = delivery_target_fixture(target_owner)
      goal = task_fixture(column, %{type: :goal, target_id: target.id})
      scope = Scope.for_user(target_owner)

      assert Interventions.can_intervene?(scope, goal)
    end

    test "returns true for a user who is both target owner and board owner", %{
      board_owner: board_owner,
      column: column
    } do
      target = delivery_target_fixture(board_owner)
      goal = task_fixture(column, %{type: :goal, target_id: target.id})
      scope = Scope.for_user(board_owner)

      assert Interventions.can_intervene?(scope, goal)
    end

    test "returns true for the board owner even when the goal has no delivery target",
         %{board_owner: board_owner, column: column} do
      goal = task_fixture(column, %{type: :goal})
      scope = Scope.for_user(board_owner)

      assert goal.target_id == nil
      assert Interventions.can_intervene?(scope, goal)
    end

    test "returns false for a non-owner who can read the board", %{
      board_owner: board_owner,
      board: board,
      column: column
    } do
      reader = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, reader, :read_only, board_owner)
      goal = task_fixture(column, %{type: :goal})
      scope = Scope.for_user(reader)

      refute Interventions.can_intervene?(scope, goal)
    end

    test "returns false when the goal is on a board the target owner cannot access",
         %{board: board, column: column} do
      # target_owner owns the target but is NOT a member of the goal's board.
      target_owner = user_fixture()
      target = delivery_target_fixture(target_owner)
      goal = task_fixture(column, %{type: :goal, target_id: target.id})
      scope = Scope.for_user(target_owner)

      # Sanity: without the board-access guard, target ownership alone would pass.
      assert Targets.owner?(target, target_owner)
      refute Boards.owner?(board, target_owner)

      refute Interventions.can_intervene?(scope, goal)
    end

    test "returns false for a nil scope", %{column: column} do
      goal = task_fixture(column, %{type: :goal})

      refute Interventions.can_intervene?(nil, goal)
    end

    test "returns false for a scope with a nil user", %{column: column} do
      goal = task_fixture(column, %{type: :goal})

      refute Interventions.can_intervene?(%Scope{user: nil}, goal)
    end
  end
end
