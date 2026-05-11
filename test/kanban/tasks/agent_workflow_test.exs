defmodule Kanban.Tasks.AgentWorkflowTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.AgentWorkflow
  alias Kanban.Tasks.Task

  defp setup_board(_ctx) do
    user = user_fixture()
    other = user_fixture()
    board = ai_optimized_board_fixture(user)
    columns = Kanban.Columns.list_columns(board)

    %{
      user: user,
      other: other,
      board: board,
      ready: Enum.find(columns, &(&1.name == "Ready")),
      doing: Enum.find(columns, &(&1.name == "Doing")),
      review: Enum.find(columns, &(&1.name == "Review")),
      done: Enum.find(columns, &(&1.name == "Done"))
    }
  end

  defp create_open_task(column, user, attrs \\ %{}) do
    base = %{
      "title" => "Test Task #{System.unique_integer([:positive])}",
      "status" => "open",
      "human_task" => false,
      "created_by_id" => user.id
    }

    {:ok, task} = Tasks.create_task(column, Map.merge(base, attrs))
    task
  end

  defp claim_for(%Task{identifier: identifier}, user, board) do
    {:ok, claimed, _hook} =
      AgentWorkflow.claim_next_task([], user, board.id, identifier, "Test Agent")

    claimed
  end

  defp valid_complete_params do
    %{
      "completion_summary" => "Did the work",
      "actual_complexity" => "small",
      "actual_files_changed" => "lib/foo.ex, lib/bar.ex",
      "time_spent_minutes" => 30
    }
  end

  describe "claim_next_task/5 — next available" do
    setup :setup_board

    test "claims the next available task and returns hook info", ctx do
      task = create_open_task(ctx.ready, ctx.user)

      assert {:ok, claimed, hook} =
               AgentWorkflow.claim_next_task([], ctx.user, ctx.board.id, nil, "Claude")

      assert claimed.id == task.id
      assert claimed.status == :in_progress
      assert claimed.assigned_to_id == ctx.user.id
      assert claimed.column_id == ctx.doing.id
      assert claimed.claimed_at
      assert claimed.claim_expires_at
      assert hook.name == "before_doing"
      assert hook.blocking == true
    end

    test "returns :no_tasks_available when nothing is open", ctx do
      assert {:error, :no_tasks_available} =
               AgentWorkflow.claim_next_task([], ctx.user, ctx.board.id)
    end

    test "broadcasts task_updated to the board topic", ctx do
      _task = create_open_task(ctx.ready, ctx.user)
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{ctx.board.id}")

      {:ok, claimed, _} =
        AgentWorkflow.claim_next_task([], ctx.user, ctx.board.id, nil, "Claude")

      assert_receive {:task_updated, broadcast}
      assert broadcast.id == claimed.id
    end

    test "claim_expires_at is roughly one hour after claimed_at", ctx do
      _task = create_open_task(ctx.ready, ctx.user)

      {:ok, claimed, _} =
        AgentWorkflow.claim_next_task([], ctx.user, ctx.board.id, nil, "Claude")

      diff = DateTime.diff(claimed.claim_expires_at, claimed.claimed_at, :second)
      assert_in_delta diff, 3600, 5
    end
  end

  describe "claim_next_task/5 — by identifier" do
    setup :setup_board

    test "claims a specific task by identifier", ctx do
      task = create_open_task(ctx.ready, ctx.user)

      assert {:ok, claimed, _hook} =
               AgentWorkflow.claim_next_task(
                 [],
                 ctx.user,
                 ctx.board.id,
                 task.identifier,
                 "Claude"
               )

      assert claimed.id == task.id
    end

    test "returns :no_tasks_available for an unknown identifier", ctx do
      assert {:error, :no_tasks_available} =
               AgentWorkflow.claim_next_task(
                 [],
                 ctx.user,
                 ctx.board.id,
                 "W999999",
                 "Claude"
               )
    end

    test "returns :assigned_to_other_user when the task is assigned to someone else", ctx do
      task = create_open_task(ctx.ready, ctx.user, %{"assigned_to_id" => ctx.other.id})

      assert {:error, :assigned_to_other_user} =
               AgentWorkflow.claim_next_task(
                 [],
                 ctx.user,
                 ctx.board.id,
                 task.identifier,
                 "Claude"
               )
    end

    test "user can claim a task explicitly assigned to themselves", ctx do
      task = create_open_task(ctx.ready, ctx.user, %{"assigned_to_id" => ctx.user.id})

      assert {:ok, claimed, _} =
               AgentWorkflow.claim_next_task(
                 [],
                 ctx.user,
                 ctx.board.id,
                 task.identifier,
                 "Claude"
               )

      assert claimed.id == task.id
      assert claimed.assigned_to_id == ctx.user.id
    end
  end

  describe "unclaim_task/3" do
    setup :setup_board

    test "moves a claimed task back to Ready and clears claim fields", ctx do
      task = create_open_task(ctx.ready, ctx.user)
      claimed = claim_for(task, ctx.user, ctx.board)

      assert {:ok, unclaimed} = AgentWorkflow.unclaim_task(claimed, ctx.user)

      assert unclaimed.status == :open
      assert unclaimed.column_id == ctx.ready.id
      assert is_nil(unclaimed.claimed_at)
      assert is_nil(unclaimed.claim_expires_at)
      assert is_nil(unclaimed.assigned_to_id)
    end

    test "returns {:error, :not_claimed} for an open task", ctx do
      task = create_open_task(ctx.ready, ctx.user)

      assert {:error, :not_claimed} = AgentWorkflow.unclaim_task(task, ctx.user)
    end

    test "returns {:error, :not_authorized} when called by a different user", ctx do
      task = create_open_task(ctx.ready, ctx.user)
      claimed = claim_for(task, ctx.user, ctx.board)

      assert {:error, :not_authorized} = AgentWorkflow.unclaim_task(claimed, ctx.other)

      reloaded = Repo.get!(Task, task.id)
      assert reloaded.status == :in_progress
      assert reloaded.assigned_to_id == ctx.user.id
    end

    test "broadcasts task_updated", ctx do
      task = create_open_task(ctx.ready, ctx.user)
      claimed = claim_for(task, ctx.user, ctx.board)

      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{ctx.board.id}")

      {:ok, unclaimed} = AgentWorkflow.unclaim_task(claimed, ctx.user, "blocked")

      assert_receive {:task_updated, broadcast}
      assert broadcast.id == unclaimed.id
      assert broadcast.status == :open
    end
  end

  describe "complete_task/4 — needs_review=true" do
    setup :setup_board

    test "moves task to Review and returns after_doing + before_review hooks", ctx do
      task = create_open_task(ctx.ready, ctx.user, %{"needs_review" => true})
      claimed = claim_for(task, ctx.user, ctx.board)

      assert {:ok, completed, hooks} =
               AgentWorkflow.complete_task(claimed, ctx.user, valid_complete_params(), "Claude")

      assert completed.column_id == ctx.review.id
      assert completed.status == :in_progress
      assert completed.completion_summary == "Did the work"
      assert completed.actual_complexity == :small
      assert completed.completed_by_id == ctx.user.id

      assert length(hooks) == 2
      assert Enum.map(hooks, & &1.name) == ["after_doing", "before_review"]
    end

    test "broadcasts task_moved_to_review", ctx do
      task = create_open_task(ctx.ready, ctx.user, %{"needs_review" => true})
      claimed = claim_for(task, ctx.user, ctx.board)

      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{ctx.board.id}")

      {:ok, completed, _hooks} =
        AgentWorkflow.complete_task(claimed, ctx.user, valid_complete_params(), "Claude")

      assert_receive {:task_moved_to_review, broadcast}
      assert broadcast.id == completed.id
    end
  end

  describe "complete_task/4 — needs_review=false" do
    setup :setup_board

    test "auto-moves to Done and returns all three hooks", ctx do
      task = create_open_task(ctx.ready, ctx.user, %{"needs_review" => false})
      claimed = claim_for(task, ctx.user, ctx.board)

      assert {:ok, final, hooks} =
               AgentWorkflow.complete_task(claimed, ctx.user, valid_complete_params(), "Claude")

      assert final.column_id == ctx.done.id
      assert final.status == :completed
      assert final.completed_at

      assert length(hooks) == 3

      assert Enum.map(hooks, & &1.name) ==
               ["after_doing", "before_review", "after_review"]
    end
  end

  describe "complete_task/4 — error paths" do
    setup :setup_board

    test "rejects a task that is not in_progress or blocked", ctx do
      task = create_open_task(ctx.ready, ctx.user)

      assert {:error, :invalid_status} =
               AgentWorkflow.complete_task(task, ctx.user, valid_complete_params(), "Claude")
    end

    test "rejects a different user's claimed task", ctx do
      task = create_open_task(ctx.ready, ctx.user)
      claimed = claim_for(task, ctx.user, ctx.board)

      assert {:error, :not_authorized} =
               AgentWorkflow.complete_task(claimed, ctx.other, valid_complete_params(), "Claude")
    end

    test "returns a changeset error when required params are missing", ctx do
      task = create_open_task(ctx.ready, ctx.user)
      claimed = claim_for(task, ctx.user, ctx.board)

      assert {:error, %Ecto.Changeset{valid?: false} = cs} =
               AgentWorkflow.complete_task(claimed, ctx.user, %{}, "Claude")

      errors = Keyword.keys(cs.errors)
      assert :completion_summary in errors
      assert :actual_complexity in errors
      assert :time_spent_minutes in errors
    end

    test "rejects negative time_spent_minutes", ctx do
      task = create_open_task(ctx.ready, ctx.user)
      claimed = claim_for(task, ctx.user, ctx.board)

      params = Map.put(valid_complete_params(), "time_spent_minutes", -5)

      assert {:error, %Ecto.Changeset{valid?: false} = cs} =
               AgentWorkflow.complete_task(claimed, ctx.user, params, "Claude")

      assert Keyword.has_key?(cs.errors, :time_spent_minutes)
    end
  end

  describe "mark_reviewed/2" do
    setup ctx do
      ctx = setup_board(ctx)
      task = create_open_task(ctx.ready, ctx.user, %{"needs_review" => true})
      claimed = claim_for(task, ctx.user, ctx.board)

      {:ok, completed, _} =
        AgentWorkflow.complete_task(claimed, ctx.user, valid_complete_params(), "Claude")

      Map.put(ctx, :in_review_task, Repo.preload(completed, [:column]))
    end

    defp set_review_status(task, status, reviewer) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      task
      |> Ecto.Changeset.change(%{
        review_status: status,
        reviewed_at: now,
        reviewed_by_id: reviewer.id
      })
      |> Repo.update!()
    end

    test "approved review moves the task to Done with status :completed", ctx do
      task = set_review_status(ctx.in_review_task, :approved, ctx.user)

      assert {:ok, done_task, hook} = AgentWorkflow.mark_reviewed(task, ctx.user)

      assert done_task.column_id == ctx.done.id
      assert done_task.status == :completed
      assert done_task.completed_at
      assert hook.name == "after_review"
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
      Kanban.Boards.add_user_to_board(ctx.board, ctx.other, :read_only)

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
      Kanban.Boards.add_user_to_board(ctx.board, ctx.other, :read_only)

      assert {:error, :not_authorized} = AgentWorkflow.mark_done(ctx.in_review_task, ctx.other)
    end
  end
end
