defmodule Kanban.Webhooks.EventsTest do
  use Kanban.DataCase, async: true
  use Oban.Testing, repo: Kanban.Repo

  import ExUnit.CaptureLog
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.LabelsFixtures
  import Kanban.TasksFixtures
  import Kanban.WebhooksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Columns
  alias Kanban.Labels
  alias Kanban.Repo
  alias Kanban.Reviews
  alias Kanban.Tasks
  alias Kanban.Tasks.Broadcaster
  alias Kanban.Webhooks.DeliveryWorker
  alias Kanban.Webhooks.Endpoint
  alias Kanban.Webhooks.Events

  setup do
    owner = user_fixture()
    board = ai_optimized_board_fixture(owner)
    cols = board |> Columns.list_columns() |> Map.new(&{&1.name, &1})
    other_board = ai_optimized_board_fixture(user_fixture())

    %{
      owner: owner,
      board: board,
      cols: cols,
      all: webhook_endpoint_fixture(board, event_types: Endpoint.event_types()),
      disabled:
        webhook_endpoint_fixture(board, event_types: Endpoint.event_types(), enabled: false),
      created_only: webhook_endpoint_fixture(board, event_types: ["task.created"]),
      other_board: webhook_endpoint_fixture(other_board, event_types: Endpoint.event_types())
    }
  end

  # {endpoint_id, event} for every queued delivery, in insertion order.
  defp queued do
    [worker: DeliveryWorker]
    |> all_enqueued()
    |> Enum.sort_by(& &1.id)
    |> Enum.map(&{&1.args["endpoint_id"], &1.args["event"]})
  end

  defp queued(event), do: Enum.filter(queued(), fn {_id, e} -> e == event end)

  defp complete_params do
    %{
      "completion_summary" => "Did the work",
      "actual_complexity" => "small",
      "actual_files_changed" => "lib/foo.ex",
      "time_spent_minutes" => 5
    }
  end

  describe "public_name/1" do
    test "maps every internal atom to its documented event name" do
      for {atom, name} <- [
            task_created: "task.created",
            task_updated: "task.updated",
            task_status_changed: "task.updated",
            task_moved: "task.moved",
            task_returned_to_doing: "task.moved",
            task_claimed: "task.claimed",
            task_unclaimed: "task.unclaimed",
            task_completed: "task.completed",
            task_moved_to_review: "task.moved_to_review",
            task_reviewed: "task.reviewed",
            task_deleted: "task.deleted"
          ] do
        assert Events.public_name(atom) == name
        assert name in Endpoint.event_types()
      end
    end

    test "returns nil for unknown atoms" do
      assert Events.public_name(:task_archived) == nil
      assert Events.public_name(:anything) == nil
    end
  end

  describe "emit/3" do
    test "queues one job per enabled subscribed endpoint on the board, none for the rest", ctx do
      task = task_fixture(ctx.cols["Backlog"])
      Repo.delete_all(Oban.Job)

      assert :ok = Events.emit(ctx.board.id, :task_updated, task)

      assert queued() == [{ctx.all.id, "task.updated"}]
    end

    test "every job of one emit carries the same envelope and its own delivery id", ctx do
      task = task_fixture(ctx.cols["Backlog"])
      Repo.delete_all(Oban.Job)
      second = webhook_endpoint_fixture(ctx.board, event_types: ["task.updated"])

      Events.emit(ctx.board.id, :task_updated, task)

      [a, b] = all_enqueued(worker: DeliveryWorker)
      assert Enum.sort([a.args["endpoint_id"], b.args["endpoint_id"]]) == [ctx.all.id, second.id]
      assert a.args["payload"] == b.args["payload"]
      assert a.args["payload"]["task"]["identifier"] == task.identifier
      refute a.args["delivery_id"] == b.args["delivery_id"]
      assert a.queue == "webhooks"
    end

    test "an unknown atom, a nil board or a task without a column queues nothing", ctx do
      task = task_fixture(ctx.cols["Backlog"])
      Repo.delete_all(Oban.Job)

      assert :ok = Events.emit(ctx.board.id, :task_archived, task)
      assert :ok = Events.emit(nil, :task_updated, task)
      assert :ok = Events.emit(ctx.board.id, :task_updated, %{task | column_id: -1, column: nil})

      assert queued() == []
    end

    test "nothing is queued when the surrounding transaction rolls back", ctx do
      task = task_fixture(ctx.cols["Backlog"])
      Repo.delete_all(Oban.Job)

      Repo.transaction(fn ->
        Events.emit(ctx.board.id, :task_updated, task)
        assert [_] = queued()
        Repo.rollback(:boom)
      end)

      assert queued() == []
    end

    test "never raises; the failure is logged with ids only", ctx do
      task = task_fixture(ctx.cols["Backlog"], %{title: "Secret title"})

      log =
        capture_log([level: :warning], fn ->
          assert :ok = Events.emit("not-an-id", :task_updated, task)
        end)

      assert log =~ "webhook event :task_updated not emitted for task #{task.id}"
      refute log =~ "Secret title"
    end
  end

  describe "task lifecycle" do
    test "creating a task queues task.created for each subscribed endpoint", ctx do
      {:ok, _task} = Tasks.create_task(ctx.cols["Backlog"], %{"title" => "New"})

      assert queued("task.created") == [
               {ctx.all.id, "task.created"},
               {ctx.created_only.id, "task.created"}
             ]
    end

    test "a failed create queues nothing", ctx do
      assert {:error, _} = Tasks.create_task(ctx.cols["Backlog"], %{"title" => ""})
      assert queued() == []
    end

    test "moving a task queues one task.moved", ctx do
      task = task_fixture(ctx.cols["Backlog"])
      {:ok, _} = Tasks.move_task(task, ctx.cols["Ready"], 0)

      assert queued("task.moved") == [{ctx.all.id, "task.moved"}]
    end

    test "claiming and unclaiming queue one task.claimed and one task.unclaimed", ctx do
      task = task_fixture(ctx.cols["Ready"], %{status: :open})

      {:ok, claimed, _hook} =
        Tasks.claim_next_task([], ctx.owner, ctx.board.id, task.identifier, "Agent")

      {:ok, _} = Tasks.unclaim_task(claimed, ctx.owner, "why")

      assert queued("task.claimed") == [{ctx.all.id, "task.claimed"}]
      assert queued("task.unclaimed") == [{ctx.all.id, "task.unclaimed"}]
    end

    test "completing a task without review queues task.moved_to_review then task.completed",
         ctx do
      completed_only = webhook_endpoint_fixture(ctx.board, event_types: ["task.completed"])
      task = task_fixture(ctx.cols["Ready"], %{status: :open, needs_review: false})

      {:ok, claimed, _hook} =
        Tasks.claim_next_task([], ctx.owner, ctx.board.id, task.identifier, "Agent")

      Repo.delete_all(Oban.Job)

      {:ok, _task, _hooks} = Tasks.complete_task(claimed, ctx.owner, complete_params(), "Agent")

      assert queued() == [
               {ctx.all.id, "task.moved_to_review"},
               {ctx.all.id, "task.completed"},
               {completed_only.id, "task.completed"}
             ]
    end

    test "approving a review queues one task.completed and one task.reviewed", ctx do
      task = pending_review_task(ctx)
      Repo.delete_all(Oban.Job)

      {:ok, _} = ctx.owner |> Scope.for_user() |> Reviews.approve_review(task)

      assert queued() == [
               {ctx.all.id, "task.completed"},
               {ctx.all.id, "task.reviewed"}
             ]
    end

    test "mark_reviewed on an approved task queues task.completed unless webhook: false", ctx do
      [emitting, silent] =
        for _ <- 1..2 do
          {:ok, task} =
            ctx
            |> pending_review_task()
            |> Tasks.update_task(%{
              review_status: :approved,
              reviewed_by_id: ctx.owner.id,
              reviewed_at: DateTime.utc_now(:second)
            })

          task
        end

      Repo.delete_all(Oban.Job)

      {:ok, _, _hooks} = Tasks.mark_reviewed(silent, ctx.owner, webhook: false)
      assert queued() == []

      {:ok, _, _hooks} = Tasks.mark_reviewed(emitting, ctx.owner)
      assert queued() == [{ctx.all.id, "task.completed"}]
    end

    test "requesting changes queues one task.reviewed; sending it back queues task.moved", ctx do
      task = pending_review_task(ctx)
      Repo.delete_all(Oban.Job)

      {:ok, reviewed} =
        ctx.owner
        |> Scope.for_user()
        |> Reviews.request_changes_review(task, review_notes: "Fix it")

      assert queued() == [{ctx.all.id, "task.reviewed"}]

      {:ok, _} = Tasks.mark_reviewed(reviewed, ctx.owner)
      assert queued("task.moved") == [{ctx.all.id, "task.moved"}]
    end

    test "deleting a task queues task.deleted with a snapshot of the task", ctx do
      task = task_fixture(ctx.cols["Backlog"], %{title: "Gone soon"})
      Repo.delete_all(Oban.Job)

      {:ok, _} = Tasks.delete_task(task)

      assert [job] = all_enqueued(worker: DeliveryWorker)
      assert job.args["event"] == "task.deleted"
      assert job.args["payload"]["task"]["title"] == "Gone soon"
    end

    test "a bulk move queues one task.moved per moved task and no task.updated", ctx do
      tasks = for _ <- 1..3, do: task_fixture(ctx.cols["Backlog"])
      Repo.delete_all(Oban.Job)

      {:ok, %{count: 3}} =
        ctx.owner
        |> Scope.for_user()
        |> Tasks.bulk_move_tasks(
          ctx.board,
          Enum.map(tasks, & &1.id),
          ctx.cols["Ready"].id
        )

      assert queued() == List.duplicate({ctx.all.id, "task.moved"}, 3)
    end

    test "promoting a goal queues one task.moved per moved task, the goal included", ctx do
      goal = task_fixture(ctx.cols["Backlog"], %{type: :goal, title: "Goal"})
      children = for _ <- 1..3, do: task_fixture(ctx.cols["Backlog"], %{parent_id: goal.id})
      Repo.delete_all(Oban.Job)

      assert {:ok, 4} = Tasks.promote_goal_to_ready(goal, ctx.board.id)

      jobs = all_enqueued(worker: DeliveryWorker)
      assert Enum.all?(jobs, &(&1.args["event"] == "task.moved"))
      assert Enum.all?(jobs, &(&1.args["endpoint_id"] == ctx.all.id))

      moved_ids = jobs |> Enum.map(& &1.args["payload"]["task"]["id"]) |> Enum.sort()
      assert moved_ids == Enum.sort([goal.id | Enum.map(children, & &1.id)])
    end

    test "a goal repositioned by its child's move emits nothing of its own", ctx do
      goal = task_fixture(ctx.cols["Backlog"], %{type: :goal, title: "Goal"})
      child = task_fixture(ctx.cols["Backlog"], %{parent_id: goal.id})
      Repo.delete_all(Oban.Job)

      {:ok, _} = Tasks.move_task(child, ctx.cols["Ready"], 0)

      assert Tasks.get_task!(goal.id).column_id == ctx.cols["Ready"].id

      assert [job] = all_enqueued(worker: DeliveryWorker)
      assert job.args["event"] == "task.moved"
      assert job.args["payload"]["task"]["id"] == child.id
    end

    test "changing a task's labels queues nothing (labels are not in the payload)", ctx do
      task = task_fixture(ctx.cols["Backlog"])
      label = label_fixture(ctx.board)
      Repo.delete_all(Oban.Job)

      {:ok, _} = ctx.owner |> Scope.for_user() |> Labels.set_task_labels(task, [label.id])

      assert queued() == []
    end

    test "broadcast_task_change with webhook: false queues nothing", ctx do
      task = task_fixture(ctx.cols["Backlog"])
      Repo.delete_all(Oban.Job)

      Broadcaster.broadcast_task_change(task, :task_updated, webhook: false)
      assert queued() == []

      Broadcaster.broadcast_task_change(task, :task_updated)
      assert queued() == [{ctx.all.id, "task.updated"}]
    end
  end

  defp pending_review_task(ctx) do
    task = task_fixture(ctx.cols["Review"])

    {:ok, task} =
      Tasks.update_task(task, %{
        needs_review: true,
        completed_by_agent: "Claude",
        completed_by_id: ctx.owner.id
      })

    task
  end
end
