defmodule Kanban.Tasks.AgentWorkflow.ReviewTest do
  @moduledoc """
  `mark_reviewed/2` and the deprecated `mark_done/2` tests for
  `Kanban.Tasks.AgentWorkflow`. Split out of `agent_workflow_test.exs` (W2356)
  with every test moved unchanged.
  """
  use Kanban.DataCase, async: true

  import Kanban.AgentWorkflowHelpers

  alias Kanban.Repo
  alias Kanban.Tasks.AgentWorkflow

  describe "mark_reviewed/2" do
    setup ctx do
      ctx = setup_board(ctx)
      task = create_open_task(ctx.ready, ctx.user, %{"needs_review" => true})
      claimed = claim_for(task, ctx.user, ctx.board)

      {:ok, completed, _} =
        AgentWorkflow.complete_task(claimed, ctx.user, valid_complete_params(), "Claude")

      Map.put(ctx, :in_review_task, Repo.preload(completed, [:column]))
    end

    test "approved review moves the task to Done with status :completed", ctx do
      task = set_review_status(ctx.in_review_task, :approved, ctx.user)

      assert {:ok, done_task, hooks} = AgentWorkflow.mark_reviewed(task, ctx.user)

      assert done_task.column_id == ctx.done.id
      assert done_task.status == :completed
      assert done_task.completed_at
      # Post-W492: hooks is a list (consistent with /complete). For an
      # orphan task with no parent goal, the list contains after_review only.
      assert Enum.map(hooks, & &1.name) == ["after_review"]
    end

    test "approved review broadcasts {:agent_event, kind: :complete} to the agents topic", ctx do
      task = set_review_status(ctx.in_review_task, :approved, ctx.user)
      task_id = task.id

      Phoenix.PubSub.subscribe(Kanban.PubSub, "agents:#{ctx.board.id}")

      assert {:ok, done_task, _hooks} = AgentWorkflow.mark_reviewed(task, ctx.user)
      assert done_task.id == task_id

      # Match this task's event on the board-scoped "agents:#{board_id}" topic (D125).
      assert_receive {:agent_event, %{kind: :complete, task_id: ^task_id}}
    end

    test "changes_requested moves the task back to Doing with status :in_progress", ctx do
      task = set_review_status(ctx.in_review_task, :changes_requested, ctx.user)

      assert {:ok, doing_task} = AgentWorkflow.mark_reviewed(task, ctx.user)

      assert doing_task.column_id == ctx.doing.id
      assert doing_task.status == :in_progress
      assert doing_task.reviewed_by_id == ctx.user.id
    end

    test "rejected moves the task back to Doing", ctx do
      task = set_review_status(ctx.in_review_task, :rejected, ctx.user)

      assert {:ok, doing_task} = AgentWorkflow.mark_reviewed(task, ctx.user)

      assert doing_task.column_id == ctx.doing.id
      assert doing_task.status == :in_progress
    end

    test "returns :review_not_performed when review_status is nil", ctx do
      assert {:error, :review_not_performed} =
               AgentWorkflow.mark_reviewed(ctx.in_review_task, ctx.user)
    end

    test "returns :invalid_column when the task is not in Review", ctx do
      task = create_open_task(ctx.ready, ctx.user)

      assert {:error, :invalid_column} = AgentWorkflow.mark_reviewed(task, ctx.user)
    end

    test "returns :not_authorized when the caller is not a board member", ctx do
      # ctx.other is a real user but has no membership on ctx.board.
      task = set_review_status(ctx.in_review_task, :approved, ctx.user)

      assert {:error, :not_authorized} = AgentWorkflow.mark_reviewed(task, ctx.other)
    end

    test "returns :not_authorized when the caller is a read-only board member", ctx do
      task = set_review_status(ctx.in_review_task, :approved, ctx.user)
      Kanban.Boards.add_user_to_board(ctx.board, ctx.other, :read_only, ctx.user)

      assert {:error, :not_authorized} = AgentWorkflow.mark_reviewed(task, ctx.other)
    end

    test "approved review broadcasts task_completed", ctx do
      task = set_review_status(ctx.in_review_task, :approved, ctx.user)

      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{ctx.board.id}")

      {:ok, _, _} = AgentWorkflow.mark_reviewed(task, ctx.user)

      assert_receive {:task_completed, broadcast}
      assert broadcast.id == task.id
    end

    test "changes_requested broadcasts task_returned_to_doing", ctx do
      task = set_review_status(ctx.in_review_task, :changes_requested, ctx.user)

      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{ctx.board.id}")

      {:ok, _} = AgentWorkflow.mark_reviewed(task, ctx.user)

      assert_receive {:task_returned_to_doing, broadcast}
      assert broadcast.id == task.id
    end
  end

  describe "mark_done/2 (deprecated)" do
    setup ctx do
      ctx = setup_board(ctx)
      task = create_open_task(ctx.ready, ctx.user, %{"needs_review" => true})
      claimed = claim_for(task, ctx.user, ctx.board)

      {:ok, completed, _} =
        AgentWorkflow.complete_task(claimed, ctx.user, valid_complete_params(), "Claude")

      Map.put(ctx, :in_review_task, Repo.preload(completed, [:column]))
    end

    test "moves a Review-column task to Done with status :completed", ctx do
      assert {:ok, done_task} = AgentWorkflow.mark_done(ctx.in_review_task, ctx.user)

      assert done_task.column_id == ctx.done.id
      assert done_task.status == :completed
      assert done_task.completed_at
    end

    test "returns :invalid_column when the task is not in Review", ctx do
      task = create_open_task(ctx.ready, ctx.user)

      assert {:error, :invalid_column} = AgentWorkflow.mark_done(task, ctx.user)
    end

    test "returns :not_authorized when the caller is not a board member", ctx do
      assert {:error, :not_authorized} = AgentWorkflow.mark_done(ctx.in_review_task, ctx.other)
    end

    test "returns :not_authorized when the caller is a read-only board member", ctx do
      Kanban.Boards.add_user_to_board(ctx.board, ctx.other, :read_only, ctx.user)

      assert {:error, :not_authorized} = AgentWorkflow.mark_done(ctx.in_review_task, ctx.other)
    end
  end
end
