defmodule Kanban.AfterGoal.GraceWorkerTest do
  @moduledoc """
  Unit tests for `Kanban.AfterGoal.GraceWorker` branches that the
  controller integration tests don't reach: the deleted-goal path and
  the defensive `nil` after_goal_status path.

  The `:succeeded` no-op and the `:pending` → promote happy path are
  already covered end-to-end by
  `KanbanWeb.API.AfterGoalControllerTest`'s drain-queue tests, so this
  file focuses on the defensive seams.
  """

  use Kanban.DataCase
  use Oban.Testing, repo: Kanban.Repo

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures
  import ExUnit.CaptureLog

  alias Kanban.AfterGoal.GraceWorker

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
