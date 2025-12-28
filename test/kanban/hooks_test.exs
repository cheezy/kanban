defmodule Kanban.HooksTest do
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Hooks
  alias Kanban.Hooks.Environment

  describe "Environment.build/3" do
    test "builds environment map with all required variables" do
      user = user_fixture()
      board = board_fixture(user, %{name: "Test Board"})
      column = column_fixture(board, %{name: "Ready"})
      task = task_fixture(column, %{
        title: "Test Task",
        description: "Test Description",
        complexity: :medium,
        priority: :high
      })

      env = Environment.build(task, board, agent_name: "Claude", hook_name: "before_doing")

      assert env["TASK_ID"] == to_string(task.id)
      assert env["TASK_IDENTIFIER"] == task.identifier
      assert env["TASK_TITLE"] == "Test Task"
      assert env["TASK_DESCRIPTION"] == "Test Description"
      assert env["TASK_COMPLEXITY"] == "medium"
      assert env["BOARD_ID"] == to_string(board.id)
      assert env["BOARD_NAME"] == "Test Board"
      assert env["COLUMN_NAME"] == "Ready"
      assert env["AGENT_NAME"] == "Claude"
      assert env["HOOK_NAME"] == "before_doing"
    end
  end

  describe "Hooks.get_hook_info/4" do
    test "returns hook metadata for valid hook" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      {:ok, hook_info} = Hooks.get_hook_info(task, board, "before_doing", "Claude Sonnet 4.5")

      assert hook_info.name == "before_doing"
      assert is_map(hook_info.env)
      assert hook_info.env["TASK_IDENTIFIER"] == task.identifier
      assert hook_info.timeout == 60_000
      assert hook_info.blocking == true
    end

    test "raises ArgumentError for invalid hook name" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      task = task_fixture(column)

      assert_raise ArgumentError, fn ->
        Hooks.get_hook_info(task, board, "invalid_hook", "Claude")
      end
    end
  end

  describe "Hooks.list_hooks/0" do
    test "returns all hook configurations" do
      hooks = Hooks.list_hooks()

      assert is_map(hooks)
      assert Map.has_key?(hooks, "before_doing")
      assert Map.has_key?(hooks, "after_doing")
      assert Map.has_key?(hooks, "before_review")
      assert Map.has_key?(hooks, "after_review")

      assert hooks["before_doing"].blocking == true
      assert hooks["after_doing"].blocking == true
      assert hooks["before_review"].blocking == false
      assert hooks["after_review"].blocking == false
    end
  end
end
