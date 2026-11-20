defmodule Kanban.Decisions.ActedOnTest do
  @moduledoc """
  Tests for `Kanban.Decisions.ActedOn` and `Kanban.Decisions.acted_on/3`:
  a person's first action on a decision emits
  `[:kanban, :decision, :acted_on]` once.
  """
  # Plan enforcement flips global application env, and the race test needs
  # the shared sandbox, so this module is not async.
  use Kanban.DataCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.DevicesFixtures
  import Kanban.PlansHelpers
  import Kanban.TasksFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.Accounts.Scope
  alias Kanban.Columns
  alias Kanban.Decisions
  alias Kanban.Decisions.ActedOn
  alias Kanban.Decisions.DecisionAction
  alias Kanban.Notifications.Events
  alias Kanban.Reviews
  alias Kanban.Tasks
  alias Kanban.Tasks.TaskClaim
  alias Kanban.Telemetry.AfterCommit

  @event [:kanban, :decision, :acted_on]

  setup do
    owner = user_fixture()
    board = ai_optimized_board_fixture(owner)
    attach_telemetry(@event)
    %{owner: owner, board: board, cols: columns(board), scope: Scope.for_user(owner)}
  end

  defp columns(board), do: board |> Columns.list_columns() |> Map.new(&{&1.name, &1})

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp pending_task!(column) do
    attrs = %{needs_review: true, completed_at: now(), completed_by_agent: "Claude"}
    {:ok, task} = column |> task_fixture() |> Tasks.update_task(attrs)
    task
  end

  defp waiting_since!(task, seconds_ago) do
    task
    |> Ecto.Changeset.change(review_requested_at: DateTime.add(now(), -seconds_ago))
    |> Repo.update!()
  end

  defp claimed!(task, user, column, claimed_at, expires_at) do
    task
    |> Ecto.Changeset.change(%{
      status: :in_progress,
      assigned_to_id: user.id,
      claimed_at: claimed_at,
      claim_expires_at: expires_at,
      column_id: column.id
    })
    |> Repo.update!()
  end

  defp released!(cols, user) do
    task = task_fixture(cols["Doing"])
    released_again!(task, cols, user)
  end

  defp released_again!(task, cols, user) do
    task = claimed!(task, user, cols["Doing"], now(), DateTime.add(now(), 3600))
    {:ok, task} = Tasks.unclaim_task(task, user, "Needs a decision")
    task
  end

  defp expired!(cols, user) do
    task =
      cols["Doing"]
      |> task_fixture()
      |> claimed!(user, cols["Doing"], DateTime.add(now(), -7200), DateTime.add(now(), -3600))

    :ok = Events.claim_expired(task)
    task
  end

  defp failed_goal!(column) do
    goal =
      column
      |> task_fixture(%{type: :goal})
      |> Ecto.Changeset.change(%{after_goal_status: :pending})
      |> Repo.update!()

    attempt = %{
      "exit_code" => 1,
      "output" => "boom",
      "duration_ms" => 4000,
      "reported_at" => "2026-11-18T10:00:00Z"
    }

    {:ok, goal} = Tasks.report_after_goal(goal, attempt)
    goal
  end

  defp agent_task!(column, completed_at) do
    {:ok, task} =
      column
      |> task_fixture()
      |> Tasks.update_task(%{
        created_by_agent: "Claude",
        completed_by_agent: "Claude",
        completed_at: completed_at,
        status: :completed
      })

    task
  end

  defp reply(scope, task, via \\ :web) do
    Decisions.acted_on(scope, [action: :reply, via: via, task_id: task.id], fn ->
      Tasks.create_comment(scope, task, %{"content" => "On it"})
    end)
  end

  defp move_to_backlog(ctx, task, via \\ :ios) do
    act = [action: :move, via: via, board_id: ctx.board.id, task_ids: [task.id]]

    Decisions.acted_on(ctx.scope, act, fn ->
      Tasks.move_to_backlog(ctx.scope, ctx.board, task)
    end)
  end

  defp rows, do: Repo.aggregate(DecisionAction, :count)

  describe "reviews" do
    test "a web approval emits acted_on with via web and wait_seconds", ctx do
      task = ctx.cols["Review"] |> pending_task!() |> waiting_since!(600)

      assert {:ok, _} = Reviews.approve_review(ctx.scope, task, via: :web)

      assert_receive {:telemetry_event, @event, measurements, metadata}
      assert measurements.count == 1
      assert measurements.wait_seconds in 600..660

      assert metadata == %{
               kind: :review,
               action: :approve,
               via: :web,
               task_id: task.id,
               board_id: ctx.board.id
             }

      refute_receive {:telemetry_event, @event, _, _}
    end

    test "app approve emits via ios", ctx do
      task = ctx.cols["Review"] |> pending_task!() |> waiting_since!(60)
      device = device_fixture(ctx.scope)

      assert {:ok, _} = Reviews.approve_review(ctx.scope, task, via: :ios, device: device)

      assert_receive {:telemetry_event, @event, %{count: 1},
                      %{kind: :review, action: :approve, via: :ios}}
    end

    test "an android request for changes emits request_changes via android", ctx do
      task = pending_task!(ctx.cols["Review"])
      device = device_fixture(ctx.scope, %{platform: :android, client_id: "stride-android"})

      assert {:ok, _} =
               Reviews.request_changes_review(ctx.scope, task,
                 review_notes: "Please add a test",
                 via: :android,
                 device: device
               )

      assert_receive {:telemetry_event, @event, _measurements,
                      %{kind: :review, action: :request_changes, via: :android}}
    end

    test "a review that comes back counts again, a refused second review does not", ctx do
      task = ctx.cols["Review"] |> pending_task!() |> waiting_since!(120)
      assert {:ok, _} = Reviews.request_changes_review(ctx.scope, task, review_notes: "No")
      assert_receive {:telemetry_event, @event, _, %{action: :request_changes}}

      assert {:error, _} = Reviews.approve_review(ctx.scope, task, via: :web)
      refute_receive {:telemetry_event, @event, _, _}

      again =
        task
        |> Repo.reload!()
        |> Ecto.Changeset.change(%{review_status: nil, review_requested_at: now()})
        |> Repo.update!()

      assert {:ok, _} = Reviews.approve_review(ctx.scope, again, via: :web)
      assert_receive {:telemetry_event, @event, %{wait_seconds: wait}, %{action: :approve}}
      assert wait in 0..5
    end

    test "a review that rolls back with its outer transaction emits and records nothing", ctx do
      task = pending_task!(ctx.cols["Review"])

      assert {:error, :rolled_back} =
               AfterCommit.after_commit(fn ->
                 Repo.transaction(fn ->
                   {:ok, _} = Reviews.approve_review(ctx.scope, task, via: :web)
                   Repo.rollback(:rolled_back)
                 end)
               end)

      refute_receive {:telemetry_event, @event, _, _}
      assert rows() == 0
    end

    test "a review on a board the plan locks emits nothing", ctx do
      enforce_plans()
      task = pending_task!(ctx.cols["Review"])

      Reviews.approve_review(ctx.scope, task, via: :web)

      refute_receive {:telemetry_event, @event, _, _}
    end
  end

  describe "moves and replies" do
    test "an action on a task that is no decision emits nothing", ctx do
      task = task_fixture(ctx.cols["Backlog"])

      assert {:ok, _} = reply(ctx.scope, task)
      assert {:ok, _} = move_to_backlog(ctx, task)

      act = [action: :move, via: :web, board_id: ctx.board.id, task_ids: [task.id]]

      assert {:ok, _} =
               Decisions.acted_on(ctx.scope, act, fn ->
                 Tasks.move_task(task, ctx.cols["Doing"], 0)
               end)

      refute_receive {:telemetry_event, @event, _, _}
      assert rows() == 0
    end

    test "an agent's comment on a released task emits nothing", ctx do
      task = released!(ctx.cols, ctx.owner)

      assert {:ok, _} =
               Tasks.create_comment(ctx.scope, task, %{"content" => "From an agent"},
                 author_agent_name: "Claude"
               )

      refute_receive {:telemetry_event, @event, _, _}
    end

    test "a reply on a released task emits reply with its board and task", ctx do
      task = released!(ctx.cols, ctx.owner)

      assert {:ok, _} = reply(ctx.scope, task, :android)

      assert_receive {:telemetry_event, @event, %{count: 1, wait_seconds: wait}, metadata}
      assert wait in 0..5

      assert metadata == %{
               kind: :released,
               action: :reply,
               via: :android,
               task_id: task.id,
               board_id: ctx.board.id
             }
    end

    test "a second action on the same decision emits nothing", ctx do
      task = released!(ctx.cols, ctx.owner)

      assert {:ok, _} = reply(ctx.scope, task)
      assert_receive {:telemetry_event, @event, _, %{kind: :released, action: :reply}}

      assert {:ok, _} = reply(ctx.scope, task)
      refute_receive {:telemetry_event, @event, _, _}

      assert {:ok, %{moved: true}} = move_to_backlog(ctx, task)
      refute_receive {:telemetry_event, @event, _, _}
      assert rows() == 1
    end

    test "a released decision that comes back counts again", ctx do
      task = released!(ctx.cols, ctx.owner)
      assert {:ok, _} = reply(ctx.scope, task)
      assert_receive {:telemetry_event, @event, _, _}

      # The release notification is deduplicated per claim second.
      Process.sleep(1100)
      released_again!(Repo.reload!(task), ctx.cols, ctx.owner)
      assert {:ok, _} = reply(ctx.scope, task)
      assert_receive {:telemetry_event, @event, _, %{kind: :released}}
      assert rows() == 2
    end

    test "moving a released task to Backlog emits move", ctx do
      task = released!(ctx.cols, ctx.owner)

      assert {:ok, %{moved: true}} = move_to_backlog(ctx, task)

      assert_receive {:telemetry_event, @event, _,
                      %{kind: :released, action: :move, via: :ios, task_id: task_id}}

      assert task_id == task.id
    end

    test "moving an expired claim to Backlog emits claim_expired move", ctx do
      task = expired!(ctx.cols, ctx.owner)

      assert {:ok, %{moved: true}} = move_to_backlog(ctx, task, :android)

      assert_receive {:telemetry_event, @event, %{wait_seconds: wait},
                      %{kind: :claim_expired, action: :move, via: :android}}

      assert wait in 3600..3660
    end

    test "a reorder that leaves a released task in Ready emits nothing", ctx do
      task = released!(ctx.cols, ctx.owner)
      act = [action: :move, via: :web, board_id: ctx.board.id, task_ids: [task.id]]

      assert {:ok, _} =
               Decisions.acted_on(ctx.scope, act, fn ->
                 Tasks.move_task(Repo.reload!(task), ctx.cols["Ready"], 0)
               end)

      refute_receive {:telemetry_event, @event, _, _}
      assert rows() == 0
    end

    test "a reply on a failed goal emits hook_failed reply", ctx do
      goal = failed_goal!(ctx.cols["Doing"])

      assert {:ok, _} = reply(ctx.scope, goal)

      assert_receive {:telemetry_event, @event, _,
                      %{kind: :hook_failed, action: :reply, task_id: goal_id}}

      assert goal_id == goal.id
    end

    test "ready_empty leaves out task_id", ctx do
      backlog = task_fixture(ctx.cols["Backlog"])
      agent_task!(ctx.cols["Done"], DateTime.add(now(), -3600))
      act = [action: :move, via: :ios, board_id: ctx.board.id, task_ids: [backlog.id]]

      assert {:ok, _} =
               Decisions.acted_on(ctx.scope, act ++ [into_ready: true], fn ->
                 Tasks.promote_to_ready(ctx.scope, ctx.board, [backlog.id])
               end)

      assert_receive {:telemetry_event, @event, %{wait_seconds: wait}, metadata}
      assert wait in 3600..3660

      assert metadata == %{
               kind: :ready_empty,
               action: :promote,
               via: :ios,
               board_id: ctx.board.id
             }

      refute Map.has_key?(metadata, :task_id)
    end

    test "a move into Ready that is not tracked as one does not count ready_empty", ctx do
      backlog = task_fixture(ctx.cols["Backlog"])
      agent_task!(ctx.cols["Done"], DateTime.add(now(), -3600))
      act = [action: :move, via: :web, board_id: ctx.board.id, task_ids: [backlog.id]]

      assert {:ok, _} =
               Decisions.acted_on(ctx.scope, act ++ [into_ready: false], fn ->
                 Tasks.move_task(backlog, ctx.cols["Ready"], 0)
               end)

      refute_receive {:telemetry_event, @event, _, _}
    end

    test "two first actions at once emit one event", ctx do
      task = released!(ctx.cols, ctx.owner)

      results =
        [:web, :ios]
        |> Enum.map(fn via -> Task.async(fn -> reply(ctx.scope, task, via) end) end)
        |> Task.await_many()

      assert [{:ok, _}, {:ok, _}] = results
      assert_receive {:telemetry_event, @event, %{count: 1}, %{kind: :released}}
      refute_receive {:telemetry_event, @event, _, _}
      assert rows() == 1
    end

    test "a decision an agent resolved first is never counted", ctx do
      task = released!(ctx.cols, ctx.owner)
      :ok = TaskClaim.record(task.id, DateTime.add(DateTime.utc_now(), 1))

      assert {:ok, _} = reply(ctx.scope, task)

      refute_receive {:telemetry_event, @event, _, _}
    end

    test "a failed action emits and records nothing", ctx do
      task = released!(ctx.cols, ctx.owner)

      assert {:error, :boom} =
               Decisions.acted_on(ctx.scope, [action: :reply, via: :web, task_id: task.id], fn ->
                 {:error, :boom}
               end)

      refute_receive {:telemetry_event, @event, _, _}
      assert rows() == 0
    end

    test "no person or no access means nothing is read or counted", ctx do
      task = released!(ctx.cols, ctx.owner)
      stranger = Scope.for_user(user_fixture())
      act = [action: :reply, via: :web, task_id: task.id]

      assert {:ok, :done} = Decisions.acted_on(nil, act, fn -> {:ok, :done} end)
      assert {:ok, :done} = Decisions.acted_on(stranger, act, fn -> {:ok, :done} end)

      assert {:ok, :done} =
               Decisions.acted_on(ctx.scope, [action: :reply, via: :web, task_id: -1], fn ->
                 {:ok, :done}
               end)

      refute_receive {:telemetry_event, @event, _, _}
    end

    test "a board the plan locks counts nothing", ctx do
      task = released!(ctx.cols, ctx.owner)
      enforce_plans()

      assert {:ok, _} = reply(ctx.scope, task)

      refute_receive {:telemetry_event, @event, _, _}
    end

    test "an unknown via raises", ctx do
      assert_raise ArgumentError, ~r/unknown decision via/, fn ->
        Decisions.acted_on(ctx.scope, [action: :reply, via: :agent, task_id: 1], fn ->
          {:ok, nil}
        end)
      end
    end
  end

  describe "finish/3 and wait_seconds/2" do
    test "an action exactly at since waits 0 seconds, and one before since never below 0" do
      at = ~U[2026-11-20 10:00:00.000000Z]

      assert ActedOn.wait_seconds(at, at) == 0
      assert ActedOn.wait_seconds(at, DateTime.add(at, -30)) == 0
      assert ActedOn.wait_seconds(at, DateTime.add(at, 90)) == 90
    end

    test "records once per decision and since and skips a decision with no since", ctx do
      since = ~U[2026-11-20 10:00:00.000000Z]

      decision = %{
        id: "ready_empty:board:#{ctx.board.id}",
        kind: :ready_empty,
        since: since,
        task_id: nil,
        board_id: ctx.board.id,
        action: :promote
      }

      assert :ok = ActedOn.finish([decision, %{decision | since: nil}], :web, since)
      assert_receive {:telemetry_event, @event, %{count: 1, wait_seconds: 0}, _}

      assert :ok = ActedOn.finish([decision], :web, since)
      refute_receive {:telemetry_event, @event, _, _}
      assert rows() == 1
    end
  end
end
