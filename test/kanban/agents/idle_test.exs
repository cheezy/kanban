defmodule Kanban.Agents.IdleTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Agents
  alias Kanban.Agents.Idle
  alias Kanban.Columns
  alias Kanban.Tasks

  setup do
    owner = user_fixture()
    board = ai_optimized_board_fixture(owner)
    other = ai_optimized_board_fixture(owner)
    %{scope: Scope.for_user(owner), board: board, other: other, cols: columns(board)}
  end

  defp columns(board), do: board |> Columns.list_columns() |> Map.new(&{&1.name, &1})

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # Runs `fun` and counts the Repo queries this process issued meanwhile.
  defp count_queries(fun) do
    test_pid = self()
    ref = :counters.new(1, [])
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:kanban, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == test_pid, do: :counters.add(ref, 1, 1)
      end,
      nil
    )

    try do
      {fun.(), :counters.get(ref, 1)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp agent_task!(column, completed_at, agent) do
    {:ok, task} =
      column
      |> task_fixture()
      |> Tasks.update_task(%{
        created_by_agent: agent,
        completed_by_agent: agent,
        completed_at: completed_at,
        status: :completed
      })

    task
  end

  describe "count_by_board/3" do
    test "counts agents active on the board in the last 24 hours that are idle now", ctx do
      agent_task!(ctx.cols["Done"], DateTime.add(now(), -3600), "Recent")
      agent_task!(ctx.cols["Done"], DateTime.add(now(), -25 * 3600), "Stale")
      agent_task!(ctx.cols["Done"], DateTime.add(now(), -3600), "Busy")

      {:ok, _} =
        ctx.other
        |> columns()
        |> Map.fetch!("Doing")
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Busy", status: :in_progress})

      assert Idle.count_by_board(ctx.scope, [ctx.board.id, ctx.other.id], now()) ==
               %{ctx.board.id => 1, ctx.other.id => 0}
    end

    test "an archived task left in Doing does not keep its agent from being idle", ctx do
      agent_task!(ctx.cols["Done"], DateTime.add(now(), -3600), "Archiver")

      {:ok, doing} =
        ctx.other
        |> columns()
        |> Map.fetch!("Doing")
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Archiver", status: :in_progress})

      doing |> Ecto.Changeset.change(archived_at: now()) |> Kanban.Repo.update!()

      assert Idle.count_by_board(ctx.scope, [ctx.board.id, ctx.other.id], now()) ==
               %{ctx.board.id => 1, ctx.other.id => 1}

      assert ctx.scope |> Idle.idle_keys() |> MapSet.member?({"Archiver", "none"})
    end

    test "agrees with the per-board roster the decision list reads", ctx do
      agent_task!(ctx.cols["Done"], DateTime.add(now(), -600), "A")
      agent_task!(ctx.cols["Done"], DateTime.add(now(), -1200), "B")
      # Work on the other board counts there, never on this one.
      ctx.other |> columns() |> Map.fetch!("Done") |> agent_task!(DateTime.add(now(), -600), "C")

      idle = Idle.idle_keys(ctx.scope)
      cutoff = Idle.cutoff(now())

      per_board =
        Map.new([ctx.board, ctx.other], fn board ->
          count =
            [scope: ctx.scope, board_id: board.id]
            |> Agents.list_agents()
            |> Idle.recent_idle(idle, cutoff)
            |> length()

          {board.id, count}
        end)

      assert per_board == %{ctx.board.id => 2, ctx.other.id => 1}
      assert Idle.count_by_board(ctx.scope, [ctx.board.id, ctx.other.id], now()) == per_board
    end

    test "an empty board list reads nothing", ctx do
      assert {result, 0} = count_queries(fn -> Idle.count_by_board(ctx.scope, [], now()) end)
      assert result == %{}
    end

    test "cutoff is 24 hours before now" do
      at = ~U[2026-11-19 12:00:00Z]
      assert Idle.cutoff(at) == ~N[2026-11-18 12:00:00]
      assert Idle.recent_seconds() == 86_400
    end
  end
end
