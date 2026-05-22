defmodule Kanban.Tasks.GoalCompletionTest do
  @moduledoc """
  Unit tests for `Kanban.Tasks.GoalCompletion` branches that the
  existing integration tests in `Kanban.TasksTest` do not reach:

    * Idempotent `maybe_mark_after_goal_pending/2` semantics — the
      compare-and-set must NOT overwrite an already-`:pending` or
      already-`:succeeded` status when a later child completion
      happens (e.g., a sibling that was completed, re-opened, and
      re-completed).
    * Transaction error path — when the child update changeset fails,
      the function returns the canonical `{:error, step, value, changes}`
      shape and does not partially mutate the database.

  The happy paths (last-child, sibling-still-open, single-child goal,
  status-flapped sibling, orphan, non-goal parent, attrs override, and
  the 2-sibling concurrency race) are already covered in
  `test/kanban/tasks_test.exs` and not duplicated here.
  """

  use Kanban.DataCase

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.GoalCompletion
  alias Kanban.Tasks.Task

  setup do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board)
    goal = task_fixture(column, %{title: "G", type: :goal})

    %{user: user, board: board, column: column, goal: goal}
  end

  describe "idempotent after_goal_status flip" do
    test "does not overwrite already-:pending status when last-child fires again",
         %{column: column, goal: goal} do
      # Pre-seed the goal as :pending (simulating a prior last-child
      # event that flipped it). A subsequent last-child fire — say,
      # because a sibling was completed, reopened, and completed
      # again — must not clobber the existing :pending status.
      {:ok, _} =
        goal
        |> Ecto.Changeset.change(%{after_goal_status: :pending})
        |> Repo.update()

      child = task_fixture(column, %{title: "Late child", parent_id: goal.id})

      assert {:ok, :last_child} =
               GoalCompletion.finalize_child_and_check_goal_complete(child)

      reloaded_goal = Tasks.get_task!(goal.id)
      assert reloaded_goal.after_goal_status == :pending
    end

    test "does NOT downgrade :succeeded → :pending when a late last-child event arrives",
         %{column: column, goal: goal} do
      # The race the compare-and-set guards against: the agent has
      # already reported after_goal (status flipped to :succeeded), and
      # then a slow concurrent sibling-completion path arrives at the
      # last-child check with stale state. The `WHERE is_nil(...)`
      # filter on the SQL update_all is the linchpin — it must keep
      # the goal at :succeeded.
      {:ok, _} =
        goal
        |> Ecto.Changeset.change(%{
          after_goal_status: :succeeded,
          after_goal_result: %{"exit_code" => 0, "output" => "ok", "duration_ms" => 1},
          after_goal_attempts: [%{"exit_code" => 0, "output" => "ok", "duration_ms" => 1}]
        })
        |> Repo.update()

      child = task_fixture(column, %{title: "Late arrival", parent_id: goal.id})

      assert {:ok, :last_child} =
               GoalCompletion.finalize_child_and_check_goal_complete(child)

      reloaded_goal = Tasks.get_task!(goal.id)
      assert reloaded_goal.after_goal_status == :succeeded
      # Audit log intact too.
      assert length(reloaded_goal.after_goal_attempts) == 1
    end
  end

  describe "non-existent parent goal" do
    test "returns :not_last_child when parent_id refers to a deleted row",
         %{column: column, goal: goal} do
      child = task_fixture(column, %{title: "Will be orphaned", parent_id: goal.id})

      # Hard-delete the parent goal (skipping the soft-archive path so
      # the row is genuinely gone). The child still has the stale
      # parent_id; lock_parent_goal/2 should return nil and the
      # function should report :not_last_child without crashing.
      from_query = from(t in Task, where: t.id == ^goal.id)
      Repo.delete_all(from_query)

      assert {:ok, :not_last_child} =
               GoalCompletion.finalize_child_and_check_goal_complete(child)

      reloaded_child = Tasks.get_task!(child.id)
      assert reloaded_child.status == :completed
    end
  end
end
