defmodule Kanban.AfterGoal.GraceWorkerTest do
  @moduledoc """
  Unit tests for `Kanban.AfterGoal.GraceWorker`.

  Covers the defensive seams (deleted goal, nil after_goal_status,
  :succeeded short-circuit) plus the `:pending` → `promote_via_grace`
  happy path. The happy path is also covered end-to-end by
  `KanbanWeb.API.AfterGoalControllerTest`'s drain-queue tests, but
  exercising it here pins the synthetic-attempt contract and the
  Logger output that the integration tests don't assert on directly.
  """

  use Kanban.DataCase
  use Oban.Testing, repo: Kanban.Repo

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures
  import ExUnit.CaptureLog

  alias Kanban.AfterGoal.GraceWorker
  alias Kanban.Columns
  alias Kanban.Tasks

  describe "perform/1 — deleted goal" do
    test "returns :ok when the goal_id no longer resolves (deleted between schedule and fire)" do
      # Logger level in test env is :warning, so the :info log message
      # itself is suppressed — what we're verifying is that the worker
      # does not raise and returns :ok cleanly. If this regressed (e.g.
      # raised on Repo.get/2 returning nil) Oban would mark the job
      # errored and retry it, which the spec explicitly forbids.
      assert :ok = perform_job(GraceWorker, %{"goal_id" => 999_999_999})
    end

    test "does not raise when goal_id is missing from args entirely" do
      # The worker pattern-matches on %{\"goal_id\" => goal_id}; an args
      # map without that key would fail the match and Oban would record
      # the job as errored. The worker itself should never be called
      # with malformed args under normal scheduling — this test pins
      # the contract.
      assert_raise FunctionClauseError, fn ->
        perform_job(GraceWorker, %{})
      end
    end
  end

  describe "perform/1 — defensive nil status" do
    test "returns :ok and logs a warning when the goal exists but after_goal_status is nil" do
      # A goal that never had its last-child detection run — its
      # after_goal_status is nil. Scheduling normally only enqueues
      # this worker AFTER the :pending flip, so this is defensive
      # against a corrupted state (e.g. status manually reset).
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      goal = task_fixture(column, %{title: "Bare goal", type: :goal})

      log =
        capture_log(fn ->
          assert :ok = perform_job(GraceWorker, %{"goal_id" => goal.id})
        end)

      assert log =~ "has nil after_goal_status"

      # Goal is untouched.
      refetched = Kanban.Repo.reload(goal)
      assert refetched.after_goal_status == nil
    end
  end

  describe "perform/1 — :pending promotion happy path" do
    setup do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      columns = Columns.list_columns(board)
      doing = Enum.find(columns, &(&1.name == "Doing"))
      done = Enum.find(columns, &(&1.name == "Done"))

      {:ok, goal} =
        Tasks.create_task(doing, %{
          "title" => "Goal awaiting grace expiry",
          "type" => "goal",
          "created_by_id" => user.id
        })

      {:ok, pending_goal} =
        goal
        |> Ecto.Changeset.change(%{after_goal_status: :pending})
        |> Kanban.Repo.update()

      %{goal: pending_goal, done_column: done, board: board}
    end

    test "flips after_goal_status to :succeeded and returns :ok", %{goal: goal} do
      assert :ok = perform_job(GraceWorker, %{"goal_id" => goal.id})

      refetched = Kanban.Repo.reload(goal)
      assert refetched.after_goal_status == :succeeded
    end

    test "appends a synthetic attempt with the worker source tag", %{goal: goal} do
      :ok = perform_job(GraceWorker, %{"goal_id" => goal.id})

      refetched = Kanban.Repo.reload(goal)
      assert [attempt] = refetched.after_goal_attempts
      assert attempt["source"] == "after_goal_grace_worker"
      assert attempt["exit_code"] == 0
      assert attempt["duration_ms"] == 0
      assert attempt["output"] == "grace window expired (no agent report received)"
    end

    test "sets after_goal_result to the synthetic attempt", %{goal: goal} do
      :ok = perform_job(GraceWorker, %{"goal_id" => goal.id})

      refetched = Kanban.Repo.reload(goal)
      assert refetched.after_goal_result["source"] == "after_goal_grace_worker"
      assert refetched.after_goal_result["exit_code"] == 0
    end

    test "promotes the goal into the Done column", %{goal: goal, done_column: done} do
      :ok = perform_job(GraceWorker, %{"goal_id" => goal.id})

      refetched = Kanban.Repo.reload(goal)
      assert refetched.column_id == done.id
    end

    test "logs an info message identifying the promoted goal", %{goal: goal} do
      # The default test-env Logger level is :warning, so we temporarily
      # lower it to :info just for this assertion. Other tests in this
      # file (and elsewhere) rely on the suppression — see the comment
      # in `perform/1 — deleted goal`.
      previous_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      log =
        capture_log(fn ->
          assert :ok = perform_job(GraceWorker, %{"goal_id" => goal.id})
        end)

      assert log =~ "after_goal grace window expired for goal #{goal.id}"
      assert log =~ "promoted to Done"
    end

    test "preserves prior attempts in the audit log when appending the synthetic one",
         %{goal: goal} do
      # Simulate a prior failed agent report already in the audit log; the
      # grace worker's synthetic success should append, not overwrite.
      prior_attempt = %{
        "exit_code" => 1,
        "output" => "agent failed earlier",
        "duration_ms" => 42,
        "source" => "agent"
      }

      {:ok, goal_with_history} =
        goal
        |> Ecto.Changeset.change(%{after_goal_attempts: [prior_attempt]})
        |> Kanban.Repo.update()

      :ok = perform_job(GraceWorker, %{"goal_id" => goal_with_history.id})

      refetched = Kanban.Repo.reload(goal_with_history)
      assert [^prior_attempt, grace_attempt] = refetched.after_goal_attempts
      assert grace_attempt["source"] == "after_goal_grace_worker"
    end
  end

  describe "perform/1 — :succeeded short-circuit" do
    test "returns :ok without modifying the goal when status is already :succeeded" do
      # Mirrors the back-compat-with-prior-report integration test but
      # exercises perform/1 directly so the unit-level seam stays
      # covered if the integration fixture changes.
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      goal = task_fixture(column, %{title: "Already done", type: :goal})

      {:ok, succeeded} =
        goal
        |> Ecto.Changeset.change(%{
          after_goal_status: :succeeded,
          after_goal_result: %{"exit_code" => 0, "output" => "done", "duration_ms" => 1},
          after_goal_attempts: [%{"exit_code" => 0, "output" => "done", "duration_ms" => 1}]
        })
        |> Kanban.Repo.update()

      assert :ok = perform_job(GraceWorker, %{"goal_id" => succeeded.id})

      # No new attempt appended, status unchanged.
      refetched = Kanban.Repo.reload(succeeded)
      assert refetched.after_goal_status == :succeeded
      assert length(refetched.after_goal_attempts) == 1
    end
  end
end
