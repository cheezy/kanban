defmodule Kanban.Hooks.MetadataTest do
  @moduledoc """
  Covers the conditional `after_goal` serialization for `/complete` and
  `/mark_reviewed` responses (W489).
  """

  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Hooks.Metadata

  @agent_name "Claude Sonnet 4.5"

  setup do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board)
    goal = task_fixture(column, %{title: "G", type: :goal})
    child = task_fixture(column, %{title: "C", parent_id: goal.id})

    %{user: user, board: board, column: column, goal: goal, child: child}
  end

  describe "build_completion_hooks/4" do
    test "default (needs_review?: false, last_child?: false) emits the three transition hooks in execution order",
         %{board: board, child: child} do
      hooks = Metadata.build_completion_hooks(child, board, @agent_name)

      assert Enum.map(hooks, & &1.name) == ["after_doing", "before_review", "after_review"]
      refute Enum.any?(hooks, &(&1.name == "after_goal"))
    end

    test "needs_review?: true emits the two pre-review hooks only", %{
      board: board,
      child: child
    } do
      hooks = Metadata.build_completion_hooks(child, board, @agent_name, needs_review?: true)

      assert Enum.map(hooks, & &1.name) == ["after_doing", "before_review"]
    end

    test "last_child?: true appends after_goal as the final entry on the auto-done path", %{
      board: board,
      child: child
    } do
      hooks = Metadata.build_completion_hooks(child, board, @agent_name, last_child?: true)

      assert Enum.map(hooks, & &1.name) == [
               "after_doing",
               "before_review",
               "after_review",
               "after_goal"
             ]
    end

    test "last_child?: true on the needs_review path appends after_goal after before_review", %{
      board: board,
      child: child
    } do
      hooks =
        Metadata.build_completion_hooks(child, board, @agent_name,
          needs_review?: true,
          last_child?: true
        )

      assert Enum.map(hooks, & &1.name) == ["after_doing", "before_review", "after_goal"]
    end

    test "non-final-child response is byte-identical to the pre-after_goal shape", %{
      board: board,
      child: child
    } do
      pre_change_hooks = Metadata.build_completion_hooks(child, board, @agent_name)

      post_change_hooks =
        Metadata.build_completion_hooks(child, board, @agent_name, last_child?: false)

      assert post_change_hooks == pre_change_hooks
    end
  end

  describe "build_mark_reviewed_hooks/4" do
    test "default (last_child?: false) emits only after_review", %{
      board: board,
      child: child
    } do
      hooks = Metadata.build_mark_reviewed_hooks(child, board, @agent_name)

      assert Enum.map(hooks, & &1.name) == ["after_review"]
    end

    test "last_child?: true appends after_goal after after_review", %{
      board: board,
      child: child
    } do
      hooks = Metadata.build_mark_reviewed_hooks(child, board, @agent_name, last_child?: true)

      assert Enum.map(hooks, & &1.name) == ["after_review", "after_goal"]
    end
  end

  describe "after_goal field shape" do
    test "matches the existing hooks' shape — same keys, same value types", %{
      board: board,
      child: child
    } do
      hooks = Metadata.build_completion_hooks(child, board, @agent_name, last_child?: true)
      after_review = Enum.find(hooks, &(&1.name == "after_review"))
      after_goal = Enum.find(hooks, &(&1.name == "after_goal"))

      # Same set of keys — agents that parse the existing hooks by key
      # name see no missing fields on the new entry.
      assert Map.keys(after_review) |> Enum.sort() == Map.keys(after_goal) |> Enum.sort()

      # Field types match the existing hook's types one-for-one.
      assert is_binary(after_goal.name)
      assert after_goal.name == "after_goal"
      assert is_integer(after_goal.timeout)
      assert is_boolean(after_goal.blocking)
      assert is_map(after_goal.env)
      assert is_binary(after_goal.execute_before)
      assert is_binary(after_goal.execute_after)
      assert is_binary(after_goal.description)
    end

    test "carries the standard env vocabulary", %{board: board, child: child} do
      hooks = Metadata.build_completion_hooks(child, board, @agent_name, last_child?: true)
      after_goal = Enum.find(hooks, &(&1.name == "after_goal"))

      # HOOK_NAME must be after_goal; the rest of the env contract is
      # owned by Kanban.Hooks.Environment and verified by its own tests.
      assert after_goal.env["HOOK_NAME"] == "after_goal"
      assert after_goal.env["TASK_IDENTIFIER"] == child.identifier
    end
  end

  describe "after_goal delivery telemetry (W498)" do
    setup do
      handler_id = "after-goal-delivered-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:kanban, :api, :after_goal_delivered],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      :ok
    end

    test "emits [:kanban, :api, :after_goal_delivered] once when build_completion_hooks runs with last_child?: true",
         %{board: board, child: child, goal: goal} do
      Metadata.build_completion_hooks(child, board, @agent_name, last_child?: true)

      assert_received {:telemetry_event, [:kanban, :api, :after_goal_delivered], %{count: 1},
                       metadata}

      assert metadata.goal_id == goal.id
      assert metadata.board_id == board.id
      # project_id is aliased to board.id (the codebase has no separate
      # project schema; Board is the project-equivalent).
      assert metadata.project_id == board.id

      # Exactly once per delivery — no duplicate.
      refute_received {:telemetry_event, [:kanban, :api, :after_goal_delivered], _, _}
    end

    test "emits [:kanban, :api, :after_goal_delivered] when build_mark_reviewed_hooks runs with last_child?: true",
         %{board: board, child: child, goal: goal} do
      Metadata.build_mark_reviewed_hooks(child, board, @agent_name, last_child?: true)

      assert_received {:telemetry_event, [:kanban, :api, :after_goal_delivered], %{count: 1},
                       metadata}

      assert metadata.goal_id == goal.id
      assert metadata.board_id == board.id
      assert metadata.project_id == board.id
    end

    test "does NOT emit when build_completion_hooks runs with last_child?: false", %{
      board: board,
      child: child
    } do
      Metadata.build_completion_hooks(child, board, @agent_name, last_child?: false)

      refute_received {:telemetry_event, [:kanban, :api, :after_goal_delivered], _, _}
    end

    test "does NOT emit when build_completion_hooks runs with default opts (last_child? defaults to false)",
         %{board: board, child: child} do
      Metadata.build_completion_hooks(child, board, @agent_name)

      refute_received {:telemetry_event, [:kanban, :api, :after_goal_delivered], _, _}
    end

    test "does NOT emit when build_mark_reviewed_hooks runs with last_child?: false", %{
      board: board,
      child: child
    } do
      Metadata.build_mark_reviewed_hooks(child, board, @agent_name, last_child?: false)

      refute_received {:telemetry_event, [:kanban, :api, :after_goal_delivered], _, _}
    end
  end
end
