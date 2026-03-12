defmodule Kanban.Tasks.AgentQueriesTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.Tasks
  alias Kanban.Tasks.AgentQueries

  describe "get_next_task/2 excludes human tasks" do
    setup do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      columns = Kanban.Columns.list_columns(board)
      ready_column = Enum.find(columns, &(&1.name == "Ready"))

      %{user: user, board: board, ready_column: ready_column}
    end

    test "does not return tasks with human_task=true", %{
      ready_column: column,
      board: board,
      user: user
    } do
      {:ok, _human_task} =
        Tasks.create_task(column, %{
          "title" => "Human Only Task",
          "status" => "open",
          "human_task" => true,
          "created_by_id" => user.id
        })

      result = AgentQueries.get_next_task([], board.id)

      assert result == nil
    end

    test "returns tasks with human_task=false", %{
      ready_column: column,
      board: board,
      user: user
    } do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Agent Task",
          "status" => "open",
          "human_task" => false,
          "created_by_id" => user.id
        })

      result = AgentQueries.get_next_task([], board.id)

      assert result.id == task.id
    end

    test "skips human tasks and returns next eligible task", %{
      ready_column: column,
      board: board,
      user: user
    } do
      {:ok, _human_task} =
        Tasks.create_task(column, %{
          "title" => "Human Only Task",
          "status" => "open",
          "human_task" => true,
          "priority" => "critical",
          "created_by_id" => user.id
        })

      {:ok, agent_task} =
        Tasks.create_task(column, %{
          "title" => "Agent Task",
          "status" => "open",
          "human_task" => false,
          "priority" => "low",
          "created_by_id" => user.id
        })

      result = AgentQueries.get_next_task([], board.id)

      assert result.id == agent_task.id
    end

    test "returns nil when all available tasks are human_task=true", %{
      ready_column: column,
      board: board,
      user: user
    } do
      {:ok, _task1} =
        Tasks.create_task(column, %{
          "title" => "Human Task 1",
          "status" => "open",
          "human_task" => true,
          "created_by_id" => user.id
        })

      {:ok, _task2} =
        Tasks.create_task(column, %{
          "title" => "Human Task 2",
          "status" => "open",
          "human_task" => true,
          "created_by_id" => user.id
        })

      result = AgentQueries.get_next_task([], board.id)

      assert result == nil
    end
  end

  describe "get_specific_task_for_claim/3 excludes human tasks" do
    setup do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      columns = Kanban.Columns.list_columns(board)
      ready_column = Enum.find(columns, &(&1.name == "Ready"))

      %{user: user, board: board, ready_column: ready_column}
    end

    test "rejects tasks with human_task=true", %{
      ready_column: column,
      board: board,
      user: user
    } do
      {:ok, human_task} =
        Tasks.create_task(column, %{
          "title" => "Human Only Task",
          "status" => "open",
          "human_task" => true,
          "created_by_id" => user.id
        })

      result =
        AgentQueries.get_specific_task_for_claim(human_task.identifier, [], board.id)

      assert result == nil
    end

    test "allows tasks with human_task=false", %{
      ready_column: column,
      board: board,
      user: user
    } do
      {:ok, agent_task} =
        Tasks.create_task(column, %{
          "title" => "Agent Task",
          "status" => "open",
          "human_task" => false,
          "created_by_id" => user.id
        })

      result =
        AgentQueries.get_specific_task_for_claim(agent_task.identifier, [], board.id)

      assert result.id == agent_task.id
    end
  end
end
