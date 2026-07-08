defmodule KanbanWeb.API.AfterGoalControllerTest do
  @moduledoc """
  Integration tests for the after_goal protocol (W493 / G113):

    * `PATCH /api/tasks/:id/after_goal` endpoint behavior
    * Goal Done gating on `after_goal_status`
    * Back-compat path via the Oban grace worker
    * Idempotency on duplicate / late reports
  """

  use KanbanWeb.ConnCase
  use Oban.Testing, repo: Kanban.Repo

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.AfterGoal.GraceWorker
  alias Kanban.ApiTokens
  alias Kanban.Columns
  alias Kanban.Tasks

  @moduletag capture_log: true

  setup %{conn: conn} do
    user = user_fixture()
    board = ai_optimized_board_fixture(user)

    {:ok, {_token_struct, plain_token}} =
      ApiTokens.create_api_token(user, board, %{
        "name" => "Test Token",
        "agent_capabilities" => ["code_generation", "testing"]
      })

    columns = Columns.list_columns(board)
    doing_column = Enum.find(columns, &(&1.name == "Doing"))
    done_column = Enum.find(columns, &(&1.name == "Done"))

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{plain_token}")

    %{
      conn: conn,
      user: user,
      board: board,
      doing_column: doing_column,
      done_column: done_column
    }
  end

  defp valid_completion_params do
    %{
      "completion_summary" => "Implemented feature",
      "actual_complexity" => "small",
      "actual_files_changed" => "1 file",
      "time_spent_minutes" => 10,
      "after_doing_result" => %{
        "exit_code" => 0,
        "output" => "tests pass",
        "duration_ms" => 100
      },
      "before_review_result" => %{
        "exit_code" => 0,
        "output" => "PR created",
        "duration_ms" => 100
      }
    }
  end

  defp create_goal_with_single_child(ctx) do
    %{user: user, doing_column: doing_column} = ctx

    {:ok, goal} =
      Tasks.create_task(doing_column, %{
        "title" => "Goal-#{System.unique_integer([:positive])}",
        "type" => "goal",
        "created_by_id" => user.id
      })

    {:ok, child} =
      Tasks.create_task(doing_column, %{
        "title" => "Only child",
        "status" => "in_progress",
        "needs_review" => false,
        "claimed_at" => DateTime.utc_now(),
        "claim_expires_at" => DateTime.add(DateTime.utc_now(), 3600, :second),
        "assigned_to_id" => user.id,
        "created_by_id" => user.id,
        "parent_id" => goal.id
      })

    %{goal: goal, child: child}
  end

  describe "auto-done last-child completion sets after_goal_status :pending and gates goal Done" do
    test "goal stays In Progress (not in Done) until after_goal reports succeeded", ctx do
      %{conn: conn, done_column: done_column} = ctx
      %{goal: goal, child: child} = create_goal_with_single_child(ctx)

      patch(conn, ~p"/api/tasks/#{child.id}/complete", valid_completion_params())

      reloaded_goal = Tasks.get_task!(goal.id)
      assert reloaded_goal.after_goal_status == :pending
      refute reloaded_goal.column_id == done_column.id
    end

    test "Oban grace worker is enqueued on last-child completion", ctx do
      %{conn: conn} = ctx
      %{goal: goal, child: child} = create_goal_with_single_child(ctx)

      patch(conn, ~p"/api/tasks/#{child.id}/complete", valid_completion_params())

      assert_enqueued(worker: GraceWorker, args: %{"goal_id" => goal.id})
    end
  end

  describe "PATCH /api/tasks/:id/after_goal — success path" do
    test "exit_code 0 flips status to :succeeded and promotes goal to Done", ctx do
      %{conn: conn, done_column: done_column} = ctx
      %{goal: goal, child: child} = create_goal_with_single_child(ctx)
      patch(conn, ~p"/api/tasks/#{child.id}/complete", valid_completion_params())

      conn =
        patch(conn, ~p"/api/tasks/#{goal.id}/after_goal", %{
          "exit_code" => 0,
          "output" => "after_goal ran",
          "duration_ms" => 1234
        })

      assert json_response(conn, 200)
      reloaded_goal = Tasks.get_task!(goal.id)
      assert reloaded_goal.after_goal_status == :succeeded
      assert reloaded_goal.column_id == done_column.id
      assert reloaded_goal.after_goal_result["exit_code"] == 0
      assert reloaded_goal.after_goal_result["output"] == "after_goal ran"
      assert length(reloaded_goal.after_goal_attempts) == 1
    end

    test "result has reported_at timestamp appended by the server", ctx do
      %{conn: conn} = ctx
      %{goal: goal, child: child} = create_goal_with_single_child(ctx)
      patch(conn, ~p"/api/tasks/#{child.id}/complete", valid_completion_params())

      patch(conn, ~p"/api/tasks/#{goal.id}/after_goal", %{
        "exit_code" => 0,
        "output" => "ok",
        "duration_ms" => 1
      })

      reloaded_goal = Tasks.get_task!(goal.id)
      assert reloaded_goal.after_goal_result["reported_at"]
    end

    test "promotion to Done broadcasts :task_moved on the board topic", ctx do
      %{conn: conn, board: board, done_column: done_column} = ctx
      %{goal: goal, child: child} = create_goal_with_single_child(ctx)
      patch(conn, ~p"/api/tasks/#{child.id}/complete", valid_completion_params())

      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{board.id}")

      patch(conn, ~p"/api/tasks/#{goal.id}/after_goal", %{
        "exit_code" => 0,
        "output" => "ok",
        "duration_ms" => 1
      })

      assert_receive {Kanban.Tasks, :task_moved, broadcasted_goal}, 500
      assert broadcasted_goal.id == goal.id
      assert broadcasted_goal.column_id == done_column.id
    end
  end

  describe "PATCH /api/tasks/:id/after_goal — failure path" do
    test "non-zero exit appends to audit log; goal stays In Progress; succeeds on retry", ctx do
      %{conn: conn, done_column: done_column} = ctx
      %{goal: goal, child: child} = create_goal_with_single_child(ctx)
      patch(conn, ~p"/api/tasks/#{child.id}/complete", valid_completion_params())

      # First attempt: failure.
      patch(conn, ~p"/api/tasks/#{goal.id}/after_goal", %{
        "exit_code" => 1,
        "output" => "tests failed",
        "duration_ms" => 500
      })

      reloaded_goal = Tasks.get_task!(goal.id)
      assert reloaded_goal.after_goal_status == :pending
      refute reloaded_goal.column_id == done_column.id
      assert length(reloaded_goal.after_goal_attempts) == 1
      [first_attempt] = reloaded_goal.after_goal_attempts
      assert first_attempt["exit_code"] == 1

      # Second attempt: success — promotes.
      patch(conn, ~p"/api/tasks/#{goal.id}/after_goal", %{
        "exit_code" => 0,
        "output" => "all green",
        "duration_ms" => 250
      })

      retried_goal = Tasks.get_task!(goal.id)
      assert retried_goal.after_goal_status == :succeeded
      assert retried_goal.column_id == done_column.id
      assert length(retried_goal.after_goal_attempts) == 2
      assert Enum.map(retried_goal.after_goal_attempts, & &1["exit_code"]) == [1, 0]
    end
  end

  describe "back-compat: Oban grace window fallback" do
    test "draining the grace queue promotes the goal when agent never reports", ctx do
      %{conn: conn, done_column: done_column} = ctx
      %{goal: goal, child: child} = create_goal_with_single_child(ctx)
      patch(conn, ~p"/api/tasks/#{child.id}/complete", valid_completion_params())

      assert_enqueued(worker: GraceWorker, args: %{"goal_id" => goal.id})

      # Drain — simulates the grace window expiring without an agent report.
      assert %{success: 1} =
               Oban.drain_queue(queue: :after_goal_grace, with_scheduled: true)

      reloaded_goal = Tasks.get_task!(goal.id)
      assert reloaded_goal.after_goal_status == :succeeded
      assert reloaded_goal.column_id == done_column.id

      [grace_attempt] = reloaded_goal.after_goal_attempts
      assert grace_attempt["source"] == "after_goal_grace_worker"
      assert grace_attempt["exit_code"] == 0
    end

    test "agent report before grace fire makes the worker a no-op", ctx do
      %{conn: conn} = ctx
      %{goal: goal, child: child} = create_goal_with_single_child(ctx)
      patch(conn, ~p"/api/tasks/#{child.id}/complete", valid_completion_params())

      # Agent reports first.
      patch(conn, ~p"/api/tasks/#{goal.id}/after_goal", %{
        "exit_code" => 0,
        "output" => "agent reported",
        "duration_ms" => 100
      })

      pre_drain_goal = Tasks.get_task!(goal.id)
      assert pre_drain_goal.after_goal_status == :succeeded
      assert length(pre_drain_goal.after_goal_attempts) == 1

      # Now drain — worker should observe :succeeded and no-op.
      Oban.drain_queue(queue: :after_goal_grace, with_scheduled: true)

      post_drain_goal = Tasks.get_task!(goal.id)
      assert post_drain_goal.after_goal_status == :succeeded
      # No additional attempts appended by the worker.
      assert length(post_drain_goal.after_goal_attempts) == 1
    end
  end

  describe "idempotency" do
    test "duplicate success report after goal already :succeeded is audit-logged but no-op",
         ctx do
      %{conn: conn, done_column: done_column} = ctx
      %{goal: goal, child: child} = create_goal_with_single_child(ctx)
      patch(conn, ~p"/api/tasks/#{child.id}/complete", valid_completion_params())

      patch(conn, ~p"/api/tasks/#{goal.id}/after_goal", %{
        "exit_code" => 0,
        "output" => "first",
        "duration_ms" => 1
      })

      # Second report after already :succeeded — must be accepted (200)
      # and appended to the audit log; no re-promotion needed.
      conn =
        patch(conn, ~p"/api/tasks/#{goal.id}/after_goal", %{
          "exit_code" => 0,
          "output" => "second",
          "duration_ms" => 2
        })

      assert json_response(conn, 200)
      reloaded_goal = Tasks.get_task!(goal.id)
      assert reloaded_goal.after_goal_status == :succeeded
      assert reloaded_goal.column_id == done_column.id
      assert length(reloaded_goal.after_goal_attempts) == 2
    end
  end

  describe "endpoint validation" do
    test "returns 422 when target task is not a goal", ctx do
      %{conn: conn, user: user, doing_column: doing_column} = ctx

      {:ok, work_task} =
        Tasks.create_task(doing_column, %{
          "title" => "Work, not a goal",
          "created_by_id" => user.id
        })

      conn =
        patch(conn, ~p"/api/tasks/#{work_task.id}/after_goal", %{
          "exit_code" => 0,
          "output" => "x",
          "duration_ms" => 1
        })

      assert response = json_response(conn, 422)
      assert response["error"] =~ "after_goal can only be reported against tasks of type goal"
    end

    test "returns 422 when goal has no in-flight after_goal lifecycle", ctx do
      %{conn: conn, user: user, doing_column: doing_column} = ctx

      {:ok, goal} =
        Tasks.create_task(doing_column, %{
          "title" => "Standalone goal",
          "type" => "goal",
          "created_by_id" => user.id
        })

      conn =
        patch(conn, ~p"/api/tasks/#{goal.id}/after_goal", %{
          "exit_code" => 0,
          "output" => "x",
          "duration_ms" => 1
        })

      assert response = json_response(conn, 422)
      assert response["error"] =~ "no in-flight after_goal lifecycle"
    end

    test "returns 422 on malformed payload (missing exit_code)", ctx do
      %{conn: conn} = ctx
      %{goal: goal, child: child} = create_goal_with_single_child(ctx)
      patch(conn, ~p"/api/tasks/#{child.id}/complete", valid_completion_params())

      conn =
        patch(conn, ~p"/api/tasks/#{goal.id}/after_goal", %{
          "output" => "no exit code",
          "duration_ms" => 1
        })

      assert response = json_response(conn, 422)
      assert response["error"] =~ "after_goal payload requires"
    end

    test "returns 422 on negative duration_ms", ctx do
      %{conn: conn} = ctx
      %{goal: goal, child: child} = create_goal_with_single_child(ctx)
      patch(conn, ~p"/api/tasks/#{child.id}/complete", valid_completion_params())

      conn =
        patch(conn, ~p"/api/tasks/#{goal.id}/after_goal", %{
          "exit_code" => 0,
          "output" => "ok",
          "duration_ms" => -1
        })

      assert json_response(conn, 422)
    end
  end

  describe "mark_reviewed path also schedules after_goal" do
    test "approved last-child review sets after_goal_status :pending and enqueues grace worker",
         ctx do
      %{conn: conn, user: user, doing_column: doing_column, board: board} = ctx
      review_column = Columns.list_columns(board) |> Enum.find(&(&1.name == "Review"))

      {:ok, goal} =
        Tasks.create_task(doing_column, %{
          "title" => "Goal needing review",
          "type" => "goal",
          "created_by_id" => user.id
        })

      {:ok, child} =
        Tasks.create_task(review_column, %{
          "title" => "Only child in review",
          "status" => "in_progress",
          "assigned_to_id" => user.id,
          "created_by_id" => user.id,
          "parent_id" => goal.id
        })

      {:ok, child} =
        Tasks.update_task(child, %{
          "review_status" => "approved",
          "reviewed_by_id" => user.id,
          "reviewed_at" => DateTime.utc_now()
        })

      patch(conn, ~p"/api/tasks/#{child.id}/mark_reviewed", %{
        "after_review_result" => %{
          "exit_code" => 0,
          "output" => "deployed",
          "duration_ms" => 100
        }
      })

      reloaded_goal = Tasks.get_task!(goal.id)
      assert reloaded_goal.after_goal_status == :pending
      assert_enqueued(worker: GraceWorker, args: %{"goal_id" => goal.id})
    end
  end

  defp create_goal_with_two_children(ctx) do
    %{user: user, doing_column: doing_column} = ctx

    {:ok, goal} =
      Tasks.create_task(doing_column, %{
        "title" => "Goal-#{System.unique_integer([:positive])}",
        "type" => "goal",
        "created_by_id" => user.id
      })

    child_attrs = fn title ->
      %{
        "title" => title,
        "status" => "in_progress",
        "needs_review" => false,
        "claimed_at" => DateTime.utc_now(),
        "claim_expires_at" => DateTime.add(DateTime.utc_now(), 3600, :second),
        "assigned_to_id" => user.id,
        "created_by_id" => user.id,
        "parent_id" => goal.id
      }
    end

    {:ok, child_a} = Tasks.create_task(doing_column, child_attrs.("Child A"))
    {:ok, child_b} = Tasks.create_task(doing_column, child_attrs.("Child B"))
    %{goal: goal, child_a: child_a, child_b: child_b}
  end

  describe "GET /api/tasks/:id/after_goal_status" do
    test "returns armed=true with goal_id/identifier and GOAL_* env for a last child", ctx do
      %{conn: conn, board: board} = ctx
      %{goal: goal, child: child} = create_goal_with_single_child(ctx)

      # Completing the only child arms the goal's after_goal (status :pending).
      patch(conn, ~p"/api/tasks/#{child.id}/complete", valid_completion_params())
      goal = Tasks.get_task!(goal.id)
      assert goal.after_goal_status == :pending

      conn = get(conn, ~p"/api/tasks/#{child.id}/after_goal_status")
      body = json_response(conn, 200)

      assert body["after_goal_armed"] == true
      assert body["goal_id"] == goal.id
      assert body["goal_identifier"] == goal.identifier

      env = body["env"]
      assert env["GOAL_ID"] == to_string(goal.id)
      assert env["GOAL_IDENTIFIER"] == goal.identifier
      assert env["GOAL_TITLE"] == goal.title
      assert env["HOOK_NAME"] == "after_goal"
      assert env["BOARD_ID"] == to_string(board.id)
      assert env["BOARD_NAME"] == board.name
    end

    test "returns armed=true when queried with the goal id directly", ctx do
      %{conn: conn} = ctx
      %{goal: goal, child: child} = create_goal_with_single_child(ctx)
      patch(conn, ~p"/api/tasks/#{child.id}/complete", valid_completion_params())

      conn = get(conn, ~p"/api/tasks/#{goal.id}/after_goal_status")
      body = json_response(conn, 200)

      assert body["after_goal_armed"] == true
      assert body["goal_id"] == goal.id
    end

    test "returns armed=false for a non-last-child completion", ctx do
      %{conn: conn} = ctx
      # child_b stays open in the DB, so completing child_a does NOT arm the goal.
      %{child_a: child_a} = create_goal_with_two_children(ctx)

      patch(conn, ~p"/api/tasks/#{child_a.id}/complete", valid_completion_params())

      conn = get(conn, ~p"/api/tasks/#{child_a.id}/after_goal_status")
      body = json_response(conn, 200)

      assert body["after_goal_armed"] == false
      assert body["goal_id"] == nil
      assert body["goal_identifier"] == nil
      assert body["env"] == %{}
    end

    test "returns armed=false for a task with no parent goal", ctx do
      %{conn: conn, doing_column: doing_column, user: user} = ctx

      {:ok, task} =
        Tasks.create_task(doing_column, %{
          "title" => "Standalone task",
          "created_by_id" => user.id
        })

      conn = get(conn, ~p"/api/tasks/#{task.id}/after_goal_status")
      body = json_response(conn, 200)

      assert body["after_goal_armed"] == false
      assert body["goal_id"] == nil
      assert body["env"] == %{}
    end

    test "response is compact — exactly the four keys, no reviewer_result", ctx do
      %{conn: conn} = ctx
      %{child: child} = create_goal_with_single_child(ctx)
      patch(conn, ~p"/api/tasks/#{child.id}/complete", valid_completion_params())

      conn = get(conn, ~p"/api/tasks/#{child.id}/after_goal_status")
      body = json_response(conn, 200)

      assert body |> Map.keys() |> Enum.sort() ==
               ["after_goal_armed", "env", "goal_id", "goal_identifier"]

      refute Map.has_key?(body, "reviewer_result")
      refute Map.has_key?(body, "data")
    end

    test "returns 403 for a task on a different board", %{conn: conn, user: user} do
      other_board = ai_optimized_board_fixture(user)

      other_column =
        Columns.list_columns(other_board) |> Enum.find(&(&1.name == "Backlog"))

      {:ok, task} =
        Tasks.create_task(other_column, %{title: "Other board task", position: 0})

      conn = get(conn, ~p"/api/tasks/#{task.id}/after_goal_status")
      assert json_response(conn, 403)["error"] =~ "does not belong to this board"
    end

    test "returns 404 for an unknown id", %{conn: conn} do
      conn = get(conn, ~p"/api/tasks/999_999_999/after_goal_status")
      assert json_response(conn, 404)["error"] =~ "not found"
    end
  end
end
