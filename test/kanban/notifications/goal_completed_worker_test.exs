defmodule Kanban.Notifications.GoalCompletedWorkerTest do
  use Kanban.DataCase, async: true
  use Oban.Testing, repo: Kanban.Repo

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Columns
  alias Kanban.Notifications.GoalCompletedWorker
  alias Kanban.Notifications.Notification
  alias Kanban.Tasks.Task

  setup do
    owner = user_fixture()
    board = ai_optimized_board_fixture(owner)
    cols = board |> Columns.list_columns() |> Map.new(&{&1.name, &1})
    %{owner: owner, board: board, cols: cols}
  end

  defp completed_goal(ctx) do
    goal = task_fixture(ctx.cols["Done"], %{type: :goal, created_by_id: ctx.owner.id})

    Task
    |> where(id: ^goal.id)
    |> Repo.update_all(set: [status: :completed, completed_at: DateTime.utc_now()])

    goal
  end

  defp rows do
    Notification
    |> where(event_type: :goal_completed)
    |> Repo.all()
  end

  test "notifies once for a completed goal, even when the job runs twice", ctx do
    goal = completed_goal(ctx)

    assert :ok = perform_job(GoalCompletedWorker, %{goal_id: goal.id})
    assert :ok = perform_job(GoalCompletedWorker, %{goal_id: goal.id})

    assert [%Notification{user_id: user_id, task_id: task_id}] = rows()
    assert user_id == ctx.owner.id
    assert task_id == goal.id
  end

  test "returns :ok for a goal that no longer exists" do
    assert :ok = perform_job(GoalCompletedWorker, %{goal_id: -1})
    assert rows() == []
  end

  test "does nothing for a goal that left Done before the job ran", ctx do
    goal = task_fixture(ctx.cols["Doing"], %{type: :goal, created_by_id: ctx.owner.id})

    assert :ok = perform_job(GoalCompletedWorker, %{goal_id: goal.id})
    assert rows() == []
  end
end
