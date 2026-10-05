defmodule Kanban.Tasks.GoalPlacementTest do
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Repo
  alias Kanban.Tasks.GoalPlacement
  alias Kanban.Tasks.Task

  @old ~N[2020-01-01 00:00:00]
  @now ~U[2026-01-02 03:04:05Z]

  defp age!(tasks) do
    ids = Enum.map(tasks, & &1.id)
    from(t in Task, where: t.id in ^ids) |> Repo.update_all(set: [updated_at: @old])
    Enum.map(tasks, &Repo.reload!/1)
  end

  describe "move_goal_to_top_with_other_goals/3" do
    test "places the goal after the other goals and stamps it and the shifted tasks" do
      user = user_fixture()
      board = board_fixture(user)
      ready = column_fixture(board, %{name: "Ready"})
      doing = column_fixture(board, %{name: "Doing"})

      goal = task_fixture(ready, %{title: "Goal", type: :goal})
      other_goal = task_fixture(doing, %{title: "Other Goal", type: :goal})
      shifted = task_fixture(doing, %{title: "Shifted"})

      archived =
        doing
        |> task_fixture(%{title: "Archived"})
        |> tap(fn t ->
          from(x in Task, where: x.id == ^t.id)
          |> Repo.update_all(set: [archived_at: DateTime.utc_now(:second)])
        end)

      [goal, other_goal, shifted, archived] = age!([goal, other_goal, shifted, archived])

      assert {:ok, :moved} = GoalPlacement.move_goal_to_top_with_other_goals(goal, doing, @now)

      placed = Repo.reload!(goal)
      assert placed.column_id == doing.id
      assert placed.position == 1
      assert placed.status == :open
      assert placed.updated_at == ~N[2026-01-02 03:04:05]

      assert Repo.reload!(shifted).position == 2
      assert Repo.reload!(shifted).updated_at == ~N[2026-01-02 03:04:05]

      assert Repo.reload!(other_goal).updated_at == @old
      assert Repo.reload!(archived).updated_at == @old
      assert Repo.reload!(archived).position == archived.position
    end
  end
end
