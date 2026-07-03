defmodule KanbanWeb.BoardLive.GoalsTest do
  @moduledoc """
  Unit tests for the extracted goals-strip computation (W1446). compute_goal_progress/2
  hits the database (DataCase); the remaining functions are pure and tested with
  plain maps. The order-dependent accent-color derivation is pinned so a future
  reorder of the accent list is caught.
  """
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias KanbanWeb.BoardLive.Goals

  describe "goal_accent_color/1 and goal_accent_ink/1" do
    test "derive a stable color/ink per goal id via rem(id, 6)" do
      # id 1 -> index 1 -> {"var(--st-ready)", "var(--st-ready)"}
      assert Goals.goal_accent_color(1) == "var(--st-ready)"
      assert Goals.goal_accent_ink(1) == "var(--st-ready)"
      # id 0 -> index 0 -> the orange pair
      assert Goals.goal_accent_color(0) == "var(--stride-orange)"
      assert Goals.goal_accent_ink(0) == "var(--stride-orange-ink)"
      # wraps every 6: id 7 == id 1
      assert Goals.goal_accent_color(7) == Goals.goal_accent_color(1)
    end

    test "fall back to violet for a non-integer id" do
      assert Goals.goal_accent_color(nil) == "var(--stride-violet)"
      assert Goals.goal_accent_ink(nil) == "var(--stride-violet-ink)"
    end
  end

  describe "compute_backlog_promotable_goals/2" do
    test "returns backlog goals that have at least one backlog child" do
      columns = [%{id: 1, name: "Backlog"}, %{id: 2, name: "Ready"}]

      goal = %{id: 10, type: :goal, parent_id: nil}
      child = %{id: 11, type: :work, parent_id: 10}
      childless_goal = %{id: 20, type: :goal, parent_id: nil}

      tasks_by_column = %{1 => [goal, child, childless_goal]}

      promotable = Goals.compute_backlog_promotable_goals(columns, tasks_by_column)

      assert MapSet.member?(promotable, 10)
      refute MapSet.member?(promotable, 20)
    end

    test "returns an empty set when there is no Backlog column" do
      assert Goals.compute_backlog_promotable_goals([%{id: 1, name: "Ready"}], %{}) ==
               MapSet.new()
    end
  end

  describe "compute_active_goals/4" do
    test "shapes each goal with :name, :flow totals, and :promoted" do
      columns = [%{id: 1, name: "Doing"}]

      tasks_by_column = %{
        1 => [%{id: 100, parent_id: 10}, %{id: 101, parent_id: 10}]
      }

      goals_by_id = %{
        10 => %{
          id: 10,
          identifier: "G1",
          short: "Goal One",
          color: "c",
          ink: "i",
          inserted_at: ~N[2026-01-01 00:00:00]
        }
      }

      [goal] = Goals.compute_active_goals(tasks_by_column, columns, goals_by_id, MapSet.new())

      assert goal.name == "Goal One"
      assert goal.flow.total == 2
      assert goal.promoted == true
    end
  end

  describe "compute_goals_by_id/1" do
    test "keys goal chips by id with deterministic accent colors, ignoring non-goals" do
      tasks_by_column = %{
        1 => [
          %{
            id: 1,
            type: :goal,
            identifier: "G1",
            title: "First",
            inserted_at: ~N[2026-01-01 00:00:00]
          },
          %{
            id: 5,
            type: :work,
            identifier: "W5",
            title: "a task",
            inserted_at: ~N[2026-01-01 00:00:00]
          }
        ]
      }

      result = Goals.compute_goals_by_id(tasks_by_column)

      assert Map.keys(result) == [1]
      assert result[1].identifier == "G1"
      assert result[1].short == "First"
      assert result[1].color == Goals.goal_accent_color(1)
      assert result[1].ink == Goals.goal_accent_ink(1)
    end
  end

  describe "compute_goal_progress/2" do
    setup do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      %{board: board, column: column}
    end

    test "computes total, completed, and percentage across children", %{
      board: board,
      column: column
    } do
      goal = task_fixture(column, %{type: :goal, title: "Goal"})

      task_fixture(column, %{
        parent_id: goal.id,
        status: :completed,
        completed_at: ~U[2026-01-02 00:00:00Z]
      })

      task_fixture(column, %{parent_id: goal.id, status: :open})

      progress = Goals.compute_goal_progress(%{column.id => [goal]}, board.id)

      assert progress[goal.id] == %{total: 2, completed: 1, percentage: 50}
    end

    test "a goal with zero children reports zero progress", %{board: board, column: column} do
      goal = task_fixture(column, %{type: :goal, title: "Empty Goal"})

      progress = Goals.compute_goal_progress(%{column.id => [goal]}, board.id)

      assert progress[goal.id] == %{total: 0, completed: 0, percentage: 0}
    end
  end
end
