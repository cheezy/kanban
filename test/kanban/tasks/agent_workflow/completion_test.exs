defmodule Kanban.Tasks.AgentWorkflow.CompletionTest do
  @moduledoc """
  `complete_task/4` tests for `Kanban.Tasks.AgentWorkflow`: the needs_review
  paths, error paths, re-completion after changes were requested, board access
  (W1430), review_requested notifications (W2203) and completion telemetry.
  Split out of `agent_workflow_test.exs` (W2356) with every test moved
  unchanged; the completion_notes (D188) tests are in `completion_notes_test.exs`.
  """
  use Kanban.DataCase, async: true
  use Oban.Testing, repo: Kanban.Repo

  import Kanban.AccountsFixtures
  import Kanban.AgentWorkflowHelpers
  import Kanban.TelemetryHelpers

  alias Kanban.Notifications.EmailWorker
  alias Kanban.Notifications.Notification
  alias Kanban.Repo
  alias Kanban.Tasks.AgentWorkflow
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskTelemetry

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

    test "leaves completed_at nil — the task is not Done until the reviewer approves",
         ctx do
      task = create_open_task(ctx.ready, ctx.user, %{"needs_review" => true})
      claimed = claim_for(task, ctx.user, ctx.board)

      assert {:ok, completed, _hooks} =
               AgentWorkflow.complete_task(claimed, ctx.user, valid_complete_params(), "Claude")

      assert completed.completed_at == nil
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

    test "broadcasts {:agent_event, kind: :complete} to the agents topic", ctx do
      task = create_open_task(ctx.ready, ctx.user, %{"needs_review" => true})
      claimed = claim_for(task, ctx.user, ctx.board)
      task_id = task.id

      Phoenix.PubSub.subscribe(Kanban.PubSub, "agents:#{ctx.board.id}")

      {:ok, completed, _hooks} =
        AgentWorkflow.complete_task(claimed, ctx.user, valid_complete_params(), "Claude")

      assert completed.id == task_id

      # The agent event is broadcast to the board-scoped "agents:#{board_id}"
      # topic (D125); match this task's event specifically rather than whichever
      # {:agent_event, _} happens to land in the mailbox first.
      assert_receive {:agent_event, %{kind: :complete, task_id: ^task_id} = payload}
      assert Map.has_key?(payload, :agent_name)
      assert Map.has_key?(payload, :at)
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

    test "broadcasts {:agent_event, kind: :complete} to the agents topic", ctx do
      task = create_open_task(ctx.ready, ctx.user, %{"needs_review" => false})
      claimed = claim_for(task, ctx.user, ctx.board)
      task_id = task.id

      Phoenix.PubSub.subscribe(Kanban.PubSub, "agents:#{ctx.board.id}")

      {:ok, final, _hooks} =
        AgentWorkflow.complete_task(claimed, ctx.user, valid_complete_params(), "Claude")

      assert final.id == task_id

      # Match this task's event on the board-scoped "agents:#{board_id}" topic (D125).
      assert_receive {:agent_event, %{kind: :complete, task_id: ^task_id}}
    end

    test "emits exactly one agents-topic event (no double-broadcast)", ctx do
      task = create_open_task(ctx.ready, ctx.user, %{"needs_review" => false})
      claimed = claim_for(task, ctx.user, ctx.board)
      task_id = task.id

      Phoenix.PubSub.subscribe(Kanban.PubSub, "agents:#{ctx.board.id}")

      {:ok, _final, _hooks} =
        AgentWorkflow.complete_task(claimed, ctx.user, valid_complete_params(), "Claude")

      # Pin to this task's id so a concurrent async test's :complete event for a
      # different task cannot trip the refute.
      assert_receive {:agent_event, %{kind: :complete, task_id: ^task_id}}
      refute_receive {:agent_event, %{kind: :complete, task_id: ^task_id}}
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
      # completion_notes is cast but deliberately optional (D188)
      refute :completion_notes in errors
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

  # The facade owns the agent_name default and delegates to
  # `AgentWorkflow.Completion` (W2360); these pin both through the public API.
  describe "complete_task/3 — facade default and blocked status" do
    setup :setup_board

    test "arity 3 fills the agent name default", ctx do
      task = create_open_task(ctx.ready, ctx.user, %{"needs_review" => true})
      claimed = claim_for(task, ctx.user, ctx.board)

      assert {:ok, _completed, hooks} =
               AgentWorkflow.complete_task(claimed, ctx.user, valid_complete_params())

      assert hooks != []
      assert Enum.all?(hooks, &(&1.env["AGENT_NAME"] == "Unknown"))
    end

    test "completes a blocked task", ctx do
      task = create_open_task(ctx.ready, ctx.user, %{"needs_review" => true})
      claimed = claim_for(task, ctx.user, ctx.board)
      {:ok, blocked} = claimed |> Ecto.Changeset.change(status: :blocked) |> Repo.update()

      assert {:ok, completed, _hooks} =
               AgentWorkflow.complete_task(blocked, ctx.user, valid_complete_params(), "Claude")

      assert completed.column_id == ctx.review.id
    end
  end

  describe "complete_task/4 — re-completion after changes requested" do
    setup :setup_board

    test "clears the previous review verdict so the task re-enters the review queue", ctx do
      task = create_open_task(ctx.ready, ctx.user, %{"needs_review" => true})
      claimed = claim_for(task, ctx.user, ctx.board)

      {:ok, completed, _hooks} =
        AgentWorkflow.complete_task(claimed, ctx.user, valid_complete_params(), "Claude")

      reviewed =
        completed
        |> Repo.preload([:column])
        |> set_review_status(:changes_requested, ctx.user)

      {:ok, back_in_doing} = AgentWorkflow.mark_reviewed(reviewed, ctx.user)

      {:ok, recompleted, _hooks} =
        AgentWorkflow.complete_task(back_in_doing, ctx.user, valid_complete_params(), "Claude")

      assert recompleted.column_id == ctx.review.id
      assert is_nil(recompleted.review_status)
      assert DateTime.diff(DateTime.utc_now(), recompleted.review_requested_at) in 0..5
      assert is_nil(recompleted.reviewed_at)
      assert is_nil(recompleted.reviewed_by_id)
    end

    test "stamps review_requested_at on completion and moves it on resubmission", ctx do
      task = create_open_task(ctx.ready, ctx.user, %{"needs_review" => true})
      claimed = claim_for(task, ctx.user, ctx.board)

      {:ok, completed, _hooks} =
        AgentWorkflow.complete_task(claimed, ctx.user, valid_complete_params(), "Claude")

      assert %DateTime{} = completed.review_requested_at

      long_ago = ~U[2026-01-01 00:00:00Z]

      Task
      |> where(id: ^task.id)
      |> Repo.update_all(set: [review_requested_at: long_ago])

      reviewed =
        Task
        |> Repo.get!(task.id)
        |> Repo.preload([:column])
        |> set_review_status(:changes_requested, ctx.user)

      {:ok, back_in_doing} = AgentWorkflow.mark_reviewed(reviewed, ctx.user)

      {:ok, recompleted, _hooks} =
        AgentWorkflow.complete_task(back_in_doing, ctx.user, valid_complete_params(), "Claude")

      assert DateTime.compare(recompleted.review_requested_at, long_ago) == :gt
      assert is_nil(recompleted.completed_at)
    end

    test "a re-completed task is listed by Reviews.list_pending_reviews/1", ctx do
      task = create_open_task(ctx.ready, ctx.user, %{"needs_review" => true})
      claimed = claim_for(task, ctx.user, ctx.board)

      {:ok, completed, _hooks} =
        AgentWorkflow.complete_task(claimed, ctx.user, valid_complete_params(), "Claude")

      reviewed =
        completed
        |> Repo.preload([:column])
        |> set_review_status(:changes_requested, ctx.user)

      {:ok, back_in_doing} = AgentWorkflow.mark_reviewed(reviewed, ctx.user)

      refute Enum.any?(Kanban.Reviews.list_pending_reviews(), &(&1.id == task.id))

      {:ok, _recompleted, _hooks} =
        AgentWorkflow.complete_task(back_in_doing, ctx.user, valid_complete_params(), "Claude")

      assert Enum.any?(Kanban.Reviews.list_pending_reviews(), &(&1.id == task.id))
    end
  end

  describe "complete_task/4 — board access (W1430)" do
    setup :setup_board

    test "returns :not_authorized when the assignee was downgraded to read_only after claiming",
         ctx do
      {:ok, _} = Kanban.Boards.add_user_to_board(ctx.board, ctx.other, :modify, ctx.user)
      task = create_open_task(ctx.ready, ctx.user)
      claimed = claim_for(task, ctx.other, ctx.board)

      # The member keeps the assignment but loses write access to the board.
      {:ok, _} = Kanban.Boards.update_user_access(ctx.board, ctx.other, :read_only, ctx.user)

      assert {:error, :not_authorized} =
               AgentWorkflow.complete_task(claimed, ctx.other, valid_complete_params(), "Claude")
    end
  end

  describe "complete_task/4 — review_requested notifications (W2203)" do
    setup :setup_board

    setup ctx do
      reader = user_fixture()
      {:ok, _} = Kanban.Boards.add_user_to_board(ctx.board, ctx.other, :modify, ctx.user)
      {:ok, _} = Kanban.Boards.add_user_to_board(ctx.board, reader, :read_only, ctx.user)
      %{reader: reader}
    end

    defp review_requests(task_id) do
      Notification
      |> where(event_type: :review_requested, task_id: ^task_id)
      |> Repo.all()
    end

    test "notifies the completing owner and modify members, not read-only members", ctx do
      task = create_open_task(ctx.ready, ctx.user, %{"needs_review" => true})
      claimed = claim_for(task, ctx.user, ctx.board)

      {:ok, completed, _hooks} =
        AgentWorkflow.complete_task(claimed, ctx.user, valid_complete_params(), "Claude")

      rows = review_requests(task.id)

      notified = rows |> Enum.map(& &1.user_id) |> Enum.sort()
      assert notified == Enum.sort([ctx.user.id, ctx.other.id])
      refute Enum.any?(rows, &(&1.user_id == ctx.reader.id))

      for n <- rows do
        assert n.title == "#{completed.identifier}: #{completed.title}"
        assert n.board_id == ctx.board.id
        assert n.url_path == "/review"
        assert_enqueued(worker: EmailWorker, args: %{notification_id: n.id})
      end
    end

    test "a needs_review=false completion requests no review", ctx do
      task = create_open_task(ctx.ready, ctx.user, %{"needs_review" => false})
      claimed = claim_for(task, ctx.user, ctx.board)

      {:ok, _done, _hooks} =
        AgentWorkflow.complete_task(claimed, ctx.user, valid_complete_params(), "Claude")

      assert review_requests(task.id) == []
    end

    test "never copies completion notes or summary into the notification", ctx do
      task = create_open_task(ctx.ready, ctx.user, %{"needs_review" => true})
      claimed = claim_for(task, ctx.user, ctx.board)

      params =
        Map.merge(valid_complete_params(), %{
          "completion_summary" => "SUMMARY-MARKER",
          "completion_notes" => "NOTES-MARKER"
        })

      {:ok, _completed, _hooks} = AgentWorkflow.complete_task(claimed, ctx.user, params, "Claude")

      for n <- review_requests(task.id) do
        refute n.title =~ "MARKER"
        refute (n.body || "") =~ "MARKER"
      end
    end

    test "a re-completion after changes requested notifies again", ctx do
      task = create_open_task(ctx.ready, ctx.user, %{"needs_review" => true})
      claimed = claim_for(task, ctx.user, ctx.board)

      {:ok, completed, _hooks} =
        AgentWorkflow.complete_task(claimed, ctx.user, valid_complete_params(), "Claude")

      {:ok, back_in_doing} =
        completed
        |> Repo.preload([:column])
        |> set_review_status(:changes_requested, ctx.user)
        |> then(&AgentWorkflow.mark_reviewed(&1, ctx.user))

      # Dedupe keys use second-precision updated_at.
      Process.sleep(1_000)

      {:ok, _recompleted, _hooks} =
        AgentWorkflow.complete_task(back_in_doing, ctx.user, valid_complete_params(), "Claude")

      rows = review_requests(task.id)

      assert length(rows) == 4
      assert rows |> Enum.map(& &1.dedupe_key) |> Enum.uniq() |> length() == 2
    end

    test "sibling tasks of one goal completed concurrently each notify every member once",
         ctx do
      goal = create_open_task(ctx.ready, ctx.user, %{"type" => "goal"})

      claimed =
        for _ <- 1..2 do
          ctx.ready
          |> create_open_task(ctx.user, %{"needs_review" => true, "parent_id" => goal.id})
          |> claim_for(ctx.user, ctx.board)
        end

      claimed
      |> Elixir.Task.async_stream(fn task ->
        AgentWorkflow.complete_task(task, ctx.user, valid_complete_params(), "Claude")
      end)
      |> Enum.each(fn {:ok, result} -> assert {:ok, _completed, _hooks} = result end)

      # The task id in each dedupe key keeps siblings from colliding.
      for task <- claimed do
        assert task.parent_id == goal.id
        assert length(review_requests(task.id)) == 2
      end
    end

    test "claiming a task does not send a task_assigned notification", ctx do
      task = create_open_task(ctx.ready, ctx.user, %{"needs_review" => true})
      _claimed = claim_for(task, ctx.user, ctx.board)

      assert Notification |> where(event_type: :task_assigned) |> Repo.all() == []
    end
  end

  describe "complete_task/4 — telemetry" do
    setup :setup_board

    test "completed event carries task_id in metadata", ctx do
      task = create_open_task(ctx.ready, ctx.user, %{"needs_review" => false})
      claimed = claim_for(task, ctx.user, ctx.board)
      attach_telemetry([:kanban, :task, :completed])

      {:ok, _final, _hooks} =
        AgentWorkflow.complete_task(claimed, ctx.user, valid_complete_params(), "Claude")

      assert_receive {:telemetry_event, [:kanban, :task, :completed], measurements, metadata}
      assert measurements == %{count: 1}
      assert metadata == %{task_id: task.id, completed_by: ctx.user.id}
    end

    test "moved_to_review normalises time_spent_minutes", ctx do
      task = create_open_task(ctx.ready, ctx.user, %{"needs_review" => true})
      claimed = claim_for(task, ctx.user, ctx.board)
      attach_telemetry([:kanban, :task, :moved_to_review])
      params = Map.put(valid_complete_params(), "time_spent_minutes", "45")

      {:ok, _completed, _hooks} = AgentWorkflow.complete_task(claimed, ctx.user, params, "Claude")

      assert_receive {:telemetry_event, [:kanban, :task, :moved_to_review], measurements,
                      metadata}

      assert measurements == %{count: 1, time_spent_minutes: 45}
      assert metadata == %{task_id: task.id, completed_by_id: ctx.user.id}
    end

    test "moved_to_review omits missing time_spent_minutes" do
      # complete_task/4 requires time_spent_minutes, so a missing value cannot
      # reach this event through it; the emitter is exercised directly.
      attach_telemetry([:kanban, :task, :moved_to_review])

      :ok = TaskTelemetry.moved_to_review(%Task{id: 11, time_spent_minutes: nil}, 3)

      assert_receive {:telemetry_event, [:kanban, :task, :moved_to_review], measurements,
                      %{task_id: 11, completed_by_id: 3}}

      assert measurements == %{count: 1}
    end

    test "returned_to_doing carries task_id and the review status in metadata", ctx do
      task = create_open_task(ctx.ready, ctx.user, %{"needs_review" => true})
      claimed = claim_for(task, ctx.user, ctx.board)

      {:ok, completed, _hooks} =
        AgentWorkflow.complete_task(claimed, ctx.user, valid_complete_params(), "Claude")

      reviewed =
        completed
        |> Repo.preload([:column])
        |> set_review_status(:changes_requested, ctx.user)

      attach_telemetry([:kanban, :task, :returned_to_doing])
      {:ok, _back_in_doing} = AgentWorkflow.mark_reviewed(reviewed, ctx.user)

      assert_receive {:telemetry_event, [:kanban, :task, :returned_to_doing], measurements,
                      metadata}

      assert measurements == %{count: 1}

      assert metadata == %{
               task_id: task.id,
               reviewed_by: ctx.user.id,
               review_status: :changes_requested
             }
    end

    test "mark_reviewed and mark_done each emit completed once, straight away", ctx do
      [approved, done] =
        for _ <- 1..2 do
          task = create_open_task(ctx.ready, ctx.user, %{"needs_review" => true})
          claimed = claim_for(task, ctx.user, ctx.board)

          {:ok, completed, _hooks} =
            AgentWorkflow.complete_task(claimed, ctx.user, valid_complete_params(), "Claude")

          Repo.preload(completed, [:column])
        end

      attach_telemetry([:kanban, :task, :completed])
      approved = set_review_status(approved, :approved, ctx.user)

      # Neither runs inside Kanban.Reviews' transaction, so nothing holds the
      # event: it has been emitted by the time each call returns.
      {:ok, _done_task, _hooks} = AgentWorkflow.mark_reviewed(approved, ctx.user)
      assert_received {:telemetry_event, [:kanban, :task, :completed], %{count: 1}, reviewed_md}
      assert reviewed_md == %{task_id: approved.id, completed_by: ctx.user.id}

      {:ok, _done_task} = AgentWorkflow.mark_done(done, ctx.user)
      assert_received {:telemetry_event, [:kanban, :task, :completed], %{count: 1}, done_md}
      assert done_md == %{task_id: done.id, completed_by: ctx.user.id}

      refute_receive {:telemetry_event, [:kanban, :task, :completed], _, _}
    end
  end
end
