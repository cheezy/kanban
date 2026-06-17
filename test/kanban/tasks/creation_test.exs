defmodule Kanban.Tasks.CreationTest do
  @moduledoc """
  Regression tests for the task-creation paths (D81): an oversized varchar(255)
  field must surface as a changeset error and roll back the transaction, never
  raise a Postgres 22001 (string_data_right_truncation) and crash the request.
  """
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures

  alias Kanban.Tasks
  alias Kanban.Tasks.Task

  @over String.duplicate("a", 256)

  setup do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board)
    %{user: user, column: column}
  end

  describe "create_task/2 length validation (D81)" do
    test "returns {:error, changeset} for an over-long title instead of raising",
         %{column: column} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Tasks.create_task(column, %{"title" => @over})

      assert %{title: ["should be at most 255 character(s)"]} = errors_on(changeset)

      over_query = from(t in Task, where: t.title == ^@over)
      refute Repo.exists?(over_query)
    end

    test "accepts a title of exactly 255 characters", %{column: column} do
      title = String.duplicate("a", 255)
      assert {:ok, %Task{}} = Tasks.create_task(column, %{"title" => title})
    end
  end

  describe "create_goal_with_tasks/3 rollback (D81)" do
    test "an over-long child title errors and rolls back every sibling, without raising",
         %{column: column} do
      goal_attrs = %{"title" => "Goal D81", "type" => "goal", "priority" => "medium"}

      children = [
        %{"title" => "Valid child D81", "type" => "work"},
        %{"title" => @over, "type" => "work"}
      ]

      result = Tasks.create_goal_with_tasks(column, goal_attrs, children)

      # An error tuple (not a raised 22001) — reaching this line proves no raise.
      assert elem(result, 0) == :error

      # The transaction rolled back: neither the goal nor the valid sibling persisted.
      goal_query = from(t in Task, where: t.title == "Goal D81")
      sibling_query = from(t in Task, where: t.title == "Valid child D81")
      refute Repo.exists?(goal_query)
      refute Repo.exists?(sibling_query)
    end
  end
end
