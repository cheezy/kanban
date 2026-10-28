defmodule Kanban.Tasks.AgentWorkflow.SupportTest do
  @moduledoc """
  Unit tests for `Kanban.Tasks.AgentWorkflow.Support`, the helpers shared by
  the claim, completion and review paths (W2357). `finalize_completion/5` and
  `maybe_schedule_after_goal_grace/2` are covered through the completion,
  review and after_goal tests that exercise them end to end.
  """
  use Kanban.DataCase, async: true
  use Oban.Testing, repo: Kanban.Repo

  import Kanban.AgentWorkflowHelpers

  alias Kanban.AfterGoal.GraceWorker
  alias Kanban.Tasks.AgentWorkflow.Support

  describe "board_write_access?/2" do
    setup :setup_board

    test "board_write_access?/2 is true for the board owner and a :modify member", ctx do
      assert Support.board_write_access?(ctx.board.id, ctx.user)

      {:ok, _} = Kanban.Boards.add_user_to_board(ctx.board, ctx.other, :modify, ctx.user)

      assert Support.board_write_access?(ctx.board.id, ctx.other)
    end

    test "board_write_access?/2 is false for a :read_only member and a non-member", ctx do
      refute Support.board_write_access?(ctx.board.id, ctx.other)

      {:ok, _} = Kanban.Boards.add_user_to_board(ctx.board, ctx.other, :read_only, ctx.user)

      refute Support.board_write_access?(ctx.board.id, ctx.other)
    end
  end

  describe "get_column_by_name/2" do
    setup :setup_board

    test "get_column_by_name/2 returns the board's column with that name", ctx do
      column = Support.get_column_by_name(ctx.board.id, "Done")

      assert column.id == ctx.done.id
      assert column.board_id == ctx.board.id
    end

    test "get_column_by_name/2 returns nil when the board has no column with that name", ctx do
      assert Support.get_column_by_name(ctx.board.id, "No Such Column") == nil
    end
  end

  describe "maybe_schedule_after_goal_grace/2" do
    setup :setup_board

    test "schedules the grace job when the task is the last child of a goal", ctx do
      goal = create_open_task(ctx.ready, ctx.user, %{"type" => "goal"})
      child = create_open_task(ctx.ready, ctx.user, %{"parent_id" => goal.id})

      assert Support.maybe_schedule_after_goal_grace(child, :last_child) == :ok

      assert_enqueued(worker: GraceWorker, args: %{"goal_id" => goal.id})
    end

    test "returns :ok without scheduling when the parent is not a goal", ctx do
      parent = create_open_task(ctx.ready, ctx.user)
      child = %{create_open_task(ctx.ready, ctx.user) | parent_id: parent.id}

      assert Support.maybe_schedule_after_goal_grace(child, :last_child) == :ok

      refute_enqueued(worker: GraceWorker)
    end

    test "returns :ok without scheduling when the task has no parent", ctx do
      task = create_open_task(ctx.ready, ctx.user)

      assert Support.maybe_schedule_after_goal_grace(task, :last_child) == :ok

      refute_enqueued(worker: GraceWorker)
    end

    test "returns :ok without scheduling when the task is not the goal's last child", ctx do
      goal = create_open_task(ctx.ready, ctx.user, %{"type" => "goal"})
      child = create_open_task(ctx.ready, ctx.user, %{"parent_id" => goal.id})

      assert Support.maybe_schedule_after_goal_grace(child, :not_last_child) == :ok

      refute_enqueued(worker: GraceWorker)
    end
  end
end
