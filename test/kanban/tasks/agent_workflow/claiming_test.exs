defmodule Kanban.Tasks.AgentWorkflow.ClaimingTest do
  @moduledoc """
  Claim and unclaim tests for `Kanban.Tasks.AgentWorkflow`: next-available and
  by-identifier claims, `unclaim_task/3`, claim board access (W1430), claim and
  unclaim telemetry, and goal re-placement under column locks (D373). Split out
  of `agent_workflow_test.exs` (W2356) with every test moved unchanged.
  """
  use Kanban.DataCase, async: true
  use Oban.Testing, repo: Kanban.Repo

  import Kanban.AgentWorkflowHelpers
  import Kanban.TelemetryHelpers

  alias Kanban.ColumnLockHelpers
  alias Kanban.Notifications.EmailWorker
  alias Kanban.Notifications.Notification
  alias Kanban.Repo
  alias Kanban.Tasks.AgentWorkflow
  alias Kanban.Tasks.Task

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

    test "broadcasts {:agent_event, kind: :claim} to the agents topic", ctx do
      task = create_open_task(ctx.ready, ctx.user)
      task_id = task.id

      Phoenix.PubSub.subscribe(Kanban.PubSub, "agents:#{ctx.board.id}")

      {:ok, claimed, _} =
        AgentWorkflow.claim_next_task([], ctx.user, ctx.board.id, nil, "Claude")

      assert claimed.id == task_id

      # The agent event is now broadcast to the board-scoped "agents:#{board_id}"
      # topic (D125); match this task's event specifically. Without the claim-path
      # agents broadcast, a claim never reaches the agent activity feed live.
      assert_receive {:agent_event, %{kind: :claim, task_id: ^task_id} = payload}
      assert Map.has_key?(payload, :agent_name)
      assert Map.has_key?(payload, :at)
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

    test "a card dragged out of Ready while the claim runs is not claimed", ctx do
      task = create_open_task(ctx.ready, ctx.user)
      backlog = ctx.board |> Kanban.Columns.list_columns() |> Enum.find(&(&1.name == "Backlog"))

      # The claim found the task in Ready; the drag lands once the claim holds
      # Doing's lock, which is all a claim locks. It runs inside the claim's
      # transaction, so the claim's rollback undoes it too: what the test can
      # see is that the claim refused and wrote nothing.
      ColumnLockHelpers.on_column_lock(ctx.doing.id, fn ->
        ColumnLockHelpers.relocate!(task.id, backlog.id, 0)
      end)

      assert {:error, :no_tasks_available} =
               AgentWorkflow.claim_next_task(
                 [],
                 ctx.user,
                 ctx.board.id,
                 task.identifier,
                 "Claude"
               )

      task = Repo.get!(Task, task.id)
      assert task.column_id == ctx.ready.id
      assert task.status == :open
      assert is_nil(task.assigned_to_id)
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

    test "returns {:error, :not_authorized} when the assignee has lost board-write access (D109)",
         ctx do
      task = create_open_task(ctx.ready, ctx.user)
      claimed = claim_for(task, ctx.user, ctx.board)

      # Downgrade the assignee to read-only WITHOUT clearing the claim — the
      # in-flight/edge case the W1430 live re-check guards.
      Repo.get_by!(Kanban.Boards.BoardUser, board_id: ctx.board.id, user_id: ctx.user.id)
      |> Ecto.Changeset.change(access: :read_only)
      |> Repo.update!()

      assert {:error, :not_authorized} = AgentWorkflow.unclaim_task(claimed, ctx.user)
      assert Repo.get!(Task, task.id).status == :in_progress
    end

    # D383: the reason goes to the notification body, which cannot store a
    # NUL byte or invalid UTF-8; the unclaim is refused, not half-done.
    test "refuses a reason with a NUL byte or invalid UTF-8 and keeps the claim", ctx do
      task = create_open_task(ctx.ready, ctx.user)
      claimed = claim_for(task, ctx.user, ctx.board)

      for bad <- [<<"bad", 0, "reason">>, <<"bad", 0xFF, "reason">>] do
        assert {:error, %Ecto.Changeset{valid?: false} = cs} =
                 AgentWorkflow.unclaim_task(claimed, ctx.user, bad)

        assert cs.errors == [reason: {"contains characters that are not allowed", []}]

        reloaded = Repo.get!(Task, task.id)
        assert reloaded.status == :in_progress
        assert reloaded.assigned_to_id == ctx.user.id
      end

      refute Repo.get_by(Notification, task_id: task.id)

      assert {:ok, %Task{status: :open}} =
               AgentWorkflow.unclaim_task(claimed, ctx.user, "line one\n\ttabbed, fine")
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

    test "notifies the unclaiming user once with the reason when they created the task", ctx do
      task = create_open_task(ctx.ready, ctx.user)
      claimed = claim_for(task, ctx.user, ctx.board)

      {:ok, _unclaimed} = AgentWorkflow.unclaim_task(claimed, ctx.user, "blocked")

      assert [%Notification{} = n] = unclaimed_rows(task)
      assert n.user_id == ctx.user.id
      assert n.body == "blocked"
      assert n.dedupe_key == "task_unclaimed:#{task.id}:#{DateTime.to_unix(claimed.claimed_at)}"
      assert_enqueued(worker: EmailWorker, args: %{notification_id: n.id})
    end

    test "notifies the unclaiming user and the task creator, with no body without a reason",
         ctx do
      {:ok, _} = Kanban.Boards.add_user_to_board(ctx.board, ctx.other, :modify, ctx.user)
      task = create_open_task(ctx.ready, ctx.other)
      claimed = claim_for(task, ctx.user, ctx.board)

      {:ok, _unclaimed} = AgentWorkflow.unclaim_task(claimed, ctx.user)

      notifications = unclaimed_rows(task)

      assert notifications |> Enum.map(& &1.user_id) |> Enum.sort() ==
               Enum.sort([ctx.user.id, ctx.other.id])

      assert Enum.all?(notifications, &is_nil(&1.body))
    end

    test "a failed unclaim notifies nobody", ctx do
      open = create_open_task(ctx.ready, ctx.user)
      claimed = claim_for(create_open_task(ctx.ready, ctx.user), ctx.user, ctx.board)

      assert {:error, :not_claimed} = AgentWorkflow.unclaim_task(open, ctx.user, "why")
      assert {:error, :not_authorized} = AgentWorkflow.unclaim_task(claimed, ctx.other, "why")

      Repo.get_by!(Kanban.Boards.BoardUser, board_id: ctx.board.id, user_id: ctx.user.id)
      |> Ecto.Changeset.change(access: :read_only)
      |> Repo.update!()

      assert {:error, :not_authorized} = AgentWorkflow.unclaim_task(claimed, ctx.user, "why")
      assert unclaimed_rows(open) == []
      assert unclaimed_rows(claimed) == []
    end
  end

  defp unclaimed_rows(task) do
    Notification
    |> where(event_type: :task_unclaimed, task_id: ^task.id)
    |> Repo.all()
  end

  describe "claim_next_task/5 — board access (W1430)" do
    setup :setup_board

    test "returns :not_authorized when the caller is not a board member", ctx do
      create_open_task(ctx.ready, ctx.user)

      assert {:error, :not_authorized} =
               AgentWorkflow.claim_next_task([], ctx.other, ctx.board.id, nil, "Claude")
    end

    test "returns :not_authorized when the caller is a read-only board member", ctx do
      create_open_task(ctx.ready, ctx.user)
      {:ok, _} = Kanban.Boards.add_user_to_board(ctx.board, ctx.other, :read_only, ctx.user)

      assert {:error, :not_authorized} =
               AgentWorkflow.claim_next_task([], ctx.other, ctx.board.id, nil, "Claude")
    end

    test "allows a :modify board member to claim", ctx do
      task = create_open_task(ctx.ready, ctx.user)
      {:ok, _} = Kanban.Boards.add_user_to_board(ctx.board, ctx.other, :modify, ctx.user)

      assert {:ok, claimed, _hook} =
               AgentWorkflow.claim_next_task([], ctx.other, ctx.board.id, nil, "Claude")

      assert claimed.id == task.id
      assert claimed.assigned_to_id == ctx.other.id
    end
  end

  describe "claim and unclaim telemetry" do
    setup :setup_board

    test "claim emits claimed with task, board and user ids", ctx do
      task = create_open_task(ctx.ready, ctx.user)
      attach_telemetry([:kanban, :task, :claimed])

      {:ok, _claimed, _hook} =
        AgentWorkflow.claim_next_task([], ctx.user, ctx.board.id, task.identifier, "Claude")

      assert_receive {:telemetry_event, [:kanban, :task, :claimed], %{count: 1}, metadata}
      assert metadata == %{task_id: task.id, board_id: ctx.board.id, user_id: ctx.user.id}
      refute_receive {:telemetry_event, [:kanban, :task, :claimed], _, _}
    end

    test "no claimable task emits nothing", ctx do
      attach_telemetry([:kanban, :task, :claimed])

      assert {:error, :no_tasks_available} =
               AgentWorkflow.claim_next_task([], ctx.user, ctx.board.id, nil, "Claude")

      task = create_open_task(ctx.ready, ctx.user)

      assert {:error, :not_authorized} =
               AgentWorkflow.claim_next_task([], ctx.other, ctx.board.id, task.identifier, "C")

      refute_receive {:telemetry_event, [:kanban, :task, :claimed], _, _}
    end

    test "unclaim without reason", ctx do
      task = create_open_task(ctx.ready, ctx.user)
      claimed = claim_for(task, ctx.user, ctx.board)
      attach_telemetry([:kanban, :task, :unclaimed])

      {:ok, _} = AgentWorkflow.unclaim_task(claimed, ctx.user)

      assert_receive {:telemetry_event, [:kanban, :task, :unclaimed], %{count: 1}, metadata}

      assert metadata == %{
               task_id: task.id,
               board_id: ctx.board.id,
               user_id: ctx.user.id,
               has_reason: false
             }
    end

    test "unclaim with a reason sends has_reason, never the reason", ctx do
      task = create_open_task(ctx.ready, ctx.user)
      claimed = claim_for(task, ctx.user, ctx.board)
      attach_telemetry([:kanban, :task, :unclaimed])

      {:ok, _} = AgentWorkflow.unclaim_task(claimed, ctx.user, "Blocked on vendor quirk")

      assert_receive {:telemetry_event, [:kanban, :task, :unclaimed], _, metadata}
      assert metadata.has_reason == true
      refute inspect(metadata) =~ "vendor quirk"
    end

    test "a refused unclaim emits nothing", ctx do
      task = create_open_task(ctx.ready, ctx.user)
      attach_telemetry([:kanban, :task, :unclaimed])

      assert {:error, :not_claimed} = AgentWorkflow.unclaim_task(task, ctx.user, "  ")
      refute_receive {:telemetry_event, [:kanban, :task, :unclaimed], _, _}
    end
  end

  describe "claiming a goal's child re-places the goal under column locks (D373)" do
    setup :setup_board

    # The claim re-places the goal after its own transaction commits. A board
    # drag holding one of the goal's columns must make that re-placement wait
    # rather than renumber the column under it.
    test "claiming a goal's child re-places the goal under locks", ctx do
      goal = create_open_task(ctx.ready, ctx.user, %{"type" => "goal"})
      child = create_open_task(ctx.ready, ctx.user, %{"parent_id" => goal.id})
      _sibling = create_open_task(ctx.ready, ctx.user, %{"parent_id" => goal.id})

      # The test's own inserts locked Ready for the rest of the test, so the
      # goal is parked in Review, a column only the second session locks.
      ColumnLockHelpers.relocate!(goal.id, ctx.review.id)
      holder = ColumnLockHelpers.hold_columns([ctx.review.id], 400)

      {waited, claimed} = ColumnLockHelpers.timed(fn -> claim_for(child, ctx.user, ctx.board) end)

      assert {:ok, :held} = Elixir.Task.await(holder, 10_000)
      assert waited >= 300
      assert claimed.column_id == ctx.doing.id
      assert Repo.get!(Task, goal.id).column_id == ctx.ready.id
    end
  end
end
