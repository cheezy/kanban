defmodule Kanban.Tasks.GoalCountsTest do
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Columns
  alias Kanban.Repo
  alias Kanban.Tasks.GoalCounts

  @at ~U[2026-11-20 09:00:00Z]

  defp child(attrs) do
    Map.merge(
      %{
        parent_id: 1,
        status: :open,
        archived_at: nil,
        needs_review: false,
        review_status: nil,
        column: %{name: "Backlog"}
      },
      attrs
    )
  end

  describe "credited?/1" do
    test "a live task counts, an archived one only when completed" do
      assert %{} |> child() |> GoalCounts.credited?()
      assert %{status: :completed, archived_at: @at} |> child() |> GoalCounts.credited?()
      refute %{status: :open, archived_at: @at} |> child() |> GoalCounts.credited?()
      refute %{status: :blocked, archived_at: @at} |> child() |> GoalCounts.credited?()
    end
  end

  describe "counts/1" do
    test "counts credited tasks for total and completed, live tasks for the rest" do
      children = [
        child(%{column: %{name: "Doing"}}),
        child(%{column: %{name: " review "}}),
        child(%{status: :blocked, column: %{name: "Ready"}}),
        child(%{status: :completed, column: %{name: "Done"}}),
        child(%{status: :completed, archived_at: @at, column: %{name: "Done"}}),
        child(%{archived_at: @at, column: %{name: "Doing"}})
      ]

      assert GoalCounts.counts(children) == %{
               total: 5,
               completed: 2,
               doing: 1,
               review: 1,
               blocked: 1
             }
    end

    test "a goal with no tasks has every count at 0" do
      assert GoalCounts.counts([]) == %{total: 0, completed: 0, doing: 0, review: 0, blocked: 0}
    end
  end

  describe "waiting_on_you/1 and archived_done/1" do
    test "count pending reviews and archived completed tasks" do
      review = %{name: "Review"}

      children = [
        child(%{needs_review: true, column: review}),
        child(%{needs_review: true, review_status: :pending, column: review}),
        child(%{needs_review: true, review_status: :approved, column: review}),
        child(%{needs_review: false, column: review}),
        child(%{needs_review: true, archived_at: @at, column: review}),
        child(%{needs_review: true, column: %{name: "Doing"}}),
        child(%{status: :completed, archived_at: @at}),
        child(%{status: :open, archived_at: @at})
      ]

      assert GoalCounts.waiting_on_you(children) == 2
      assert GoalCounts.archived_done(children) == 1
      assert GoalCounts.waiting_on_you([]) == 0
      assert GoalCounts.archived_done([]) == 0
    end
  end

  describe "children_by_goal/1" do
    test "returns every task of each goal on its own board, archived ones included" do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      cols = board |> Columns.list_columns() |> Map.new(&{&1.name, &1})
      goal = task_fixture(cols["Backlog"], %{type: :goal})
      empty = task_fixture(cols["Backlog"], %{type: :goal})
      task_fixture(cols["Doing"], %{parent_id: goal.id})

      cols["Done"]
      |> task_fixture(%{parent_id: goal.id})
      |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second))
      |> Repo.update!()

      other_cols = user |> ai_optimized_board_fixture() |> Columns.list_columns()
      stray = task_fixture(hd(other_cols), %{})
      stray |> Ecto.Changeset.change(parent_id: goal.id) |> Repo.update!()

      by_goal = GoalCounts.children_by_goal([goal.id, empty.id])

      assert Map.keys(by_goal) == [goal.id]

      # The stray task on another board is not counted.
      assert by_goal[goal.id] |> Enum.map(& &1.column.name) |> Enum.sort() == ["Doing", "Done"]
      assert Enum.all?(by_goal[goal.id], &(&1.parent_id == goal.id))
      assert Enum.any?(by_goal[goal.id], &(not is_nil(&1.archived_at)))
    end

    test "makes no query for no ids" do
      assert GoalCounts.children_by_goal([]) == %{}
    end
  end
end
