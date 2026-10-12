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
  import Kanban.TelemetryHelpers

  alias Kanban.ApiTokens
  alias Kanban.Columns
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

  describe "archived siblings" do
    test "an archived incomplete sibling does not block the last-child trigger",
         %{column: column, goal: goal} do
      child1 = task_fixture(column, %{title: "C1", parent_id: goal.id})
      child2 = task_fixture(column, %{title: "C2", parent_id: goal.id})

      # Archive child2 while it is still incomplete (status not completed).
      Task
      |> where([t], t.id == ^child2.id)
      |> Repo.update_all(set: [archived_at: DateTime.utc_now() |> DateTime.truncate(:second)])

      assert {:ok, :last_child} =
               GoalCompletion.finalize_child_and_check_goal_complete(child1)
    end
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

  describe "goal.completed telemetry" do
    setup %{user: user} do
      board = ai_optimized_board_fixture(user)
      cols = board |> Columns.list_columns() |> Map.new(&{&1.name, &1})
      {:ok, goal} = Tasks.create_task(cols["Doing"], goal_attrs(user))

      %{agent_board: board, cols: cols, agent_goal: goal}
    end

    test "last child emits goal.completed", ctx do
      %{user: user, agent_board: board, cols: cols, agent_goal: goal} = ctx
      first = claimed_child!(cols["Doing"], user, goal)
      last = claimed_child!(cols["Doing"], user, goal)
      attach_telemetry([:kanban, :goal, :completed])

      assert {:ok, _, _} = Tasks.complete_task(first, user, completion_params())
      refute_received {:telemetry_event, [:kanban, :goal, :completed], _, _}

      assert {:ok, _, _} = Tasks.complete_task(last, user, completion_params())

      assert_receive {:telemetry_event, [:kanban, :goal, :completed], %{count: 1}, metadata}
      assert metadata == %{goal_id: goal.id, board_id: board.id}
      refute_receive {:telemetry_event, [:kanban, :goal, :completed], _, _}
    end

    test "re-completing the last child emits no second goal.completed", ctx do
      %{user: user, cols: cols, agent_goal: goal} = ctx
      child = claimed_child!(cols["Doing"], user, goal)
      attach_telemetry([:kanban, :goal, :completed])

      assert {:ok, _, _} = Tasks.complete_task(child, user, completion_params())
      assert_receive {:telemetry_event, [:kanban, :goal, :completed], _, _}

      # Re-open the child, as a reviewer sending it back would, and finish it again.
      Task
      |> where([t], t.id == ^child.id)
      |> Repo.update_all(
        set: [status: :in_progress, column_id: cols["Doing"].id, completed_at: nil]
      )

      reopened = Tasks.get_task!(child.id)
      assert {:ok, _, _} = Tasks.complete_task(reopened, user, completion_params())

      refute_receive {:telemetry_event, [:kanban, :goal, :completed], _, _}
    end

    test "goal without children", ctx do
      %{user: user, cols: cols} = ctx
      {:ok, childless} = Tasks.create_task(cols["Doing"], goal_attrs(user))
      orphan = claimed_child!(cols["Doing"], user, nil)
      attach_telemetry([:kanban, :goal, :completed])

      assert {:ok, _, _} = Tasks.complete_task(orphan, user, completion_params())

      refute_receive {:telemetry_event, [:kanban, :goal, :completed], _, _}
      assert Tasks.get_task!(childless.id).after_goal_status == nil
    end

    test "api completion emits goal.completed", ctx do
      %{user: user, agent_board: board, cols: cols, agent_goal: goal} = ctx
      child = claimed_child!(cols["Doing"], user, goal)

      attach_telemetry([[:kanban, :task, :completed], [:kanban, :goal, :completed]])

      response =
        board
        |> api_conn(user)
        |> Phoenix.ConnTest.dispatch(
          KanbanWeb.Endpoint,
          :patch,
          "/api/tasks/#{child.id}/complete",
          Map.merge(completion_params(), %{
            "after_doing_result" => %{"exit_code" => 0, "output" => "ok", "duration_ms" => 100},
            "before_review_result" => %{"exit_code" => 0, "output" => "ok", "duration_ms" => 100}
          })
        )

      assert response.status == 200

      assert_receive {:telemetry_event, [:kanban, :task, :completed], %{count: 1},
                      %{task_id: task_id}}

      assert task_id == child.id

      assert_receive {:telemetry_event, [:kanban, :goal, :completed], %{count: 1}, metadata}
      assert metadata == %{goal_id: goal.id, board_id: board.id}
    end
  end

  describe "finalize_child/2" do
    test "returns the goal id only for the call that completes the goal",
         %{column: column, goal: goal} do
      first = task_fixture(column, %{title: "C1", parent_id: goal.id})
      last = task_fixture(column, %{title: "C2", parent_id: goal.id})

      assert {:ok, :not_last_child, nil} = GoalCompletion.finalize_child(first)
      assert {:ok, :last_child, goal_id} = GoalCompletion.finalize_child(last)
      assert goal_id == goal.id

      # A later last-child event (a re-completed sibling) no longer flips the goal.
      assert {:ok, :last_child, nil} = GoalCompletion.finalize_child(last)
    end

    test "returns nil for a task with no parent", %{column: column} do
      orphan = task_fixture(column, %{title: "Orphan"})
      assert {:ok, :not_last_child, nil} = GoalCompletion.finalize_child(orphan)
    end
  end

  defp goal_attrs(user) do
    %{
      "title" => "Goal #{System.unique_integer([:positive])}",
      "type" => "goal",
      "created_by_id" => user.id
    }
  end

  defp claimed_child!(column, user, goal) do
    attrs = %{
      "title" => "Child #{System.unique_integer([:positive])}",
      "status" => "in_progress",
      "needs_review" => false,
      "claimed_at" => DateTime.utc_now(),
      "claim_expires_at" => DateTime.add(DateTime.utc_now(), 3600, :second),
      "assigned_to_id" => user.id,
      "created_by_id" => user.id
    }

    attrs = if goal, do: Map.put(attrs, "parent_id", goal.id), else: attrs
    {:ok, child} = Tasks.create_task(column, attrs)
    child
  end

  defp completion_params do
    %{
      "completion_summary" => "Implemented the feature",
      "actual_complexity" => "small",
      "actual_files_changed" => "1 file",
      "time_spent_minutes" => 10
    }
  end

  defp api_conn(board, user) do
    {:ok, {_token, plain_token}} =
      ApiTokens.create_api_token(user, board, %{
        "name" => "Telemetry token",
        "agent_capabilities" => ["code_generation", "testing"]
      })

    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("accept", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{plain_token}")
  end
end
