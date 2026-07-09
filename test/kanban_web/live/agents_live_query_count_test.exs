defmodule KanbanWeb.AgentsLiveQueryCountTest do
  @moduledoc """
  Regression guard for D120: the heavy board-scoped `/agents` data load
  (`fetch_task_sets/2` — two `Agents.fetch_tasks/1` sets — plus
  `DeliveryRollup.build/2`) runs ONLY on the connected mount. The disconnected
  (static) first render must not issue those reads, so it stays instant and the
  per-load query volume is not doubled by an unconditional load running on both
  the disconnected and connected mount.

  Before the fix, mounting `/agents` ran the full load twice; the static render
  alone issued the two fetch sets and the rollup reads. This test seeds a
  dataset large enough that the old path's query volume is unmistakable, then
  asserts the static render stays below a low ceiling while the connected mount
  still renders the full roster (content preserved).

  Not async — it attaches a global telemetry handler to the Repo query event.
  """
  use KanbanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TargetsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Tasks

  setup [:register_and_log_in_user]

  # Counts the Repo query telemetry events emitted while `fun` runs.
  defp count_queries(fun) do
    ref = :counters.new(1, [])
    handler_id = "d120-qc-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:kanban, :repo, :query],
      fn _event, _measurements, _metadata, _config -> :counters.add(ref, 1, 1) end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    :counters.get(ref, 1)
  end

  # A workspace with agent activity across several tasks plus a delivery target
  # with a member goal and a bridged in-progress child — enough that the old
  # unconditional load issued its full fetch_task_sets + DeliveryRollup query
  # volume on the (now deferred) disconnected render.
  defp seed_workspace(user) do
    board = board_fixture(user)
    doing = column_fixture(board, %{name: "Doing"})
    done = column_fixture(board, %{name: "Done"})

    seed_agent_tasks(doing, done)
    seed_target_with_bridged_goal(user, doing)
    :ok
  end

  defp seed_agent_tasks(doing, done) do
    for name <- ~w(Ada Claude Codex Grace) do
      {:ok, _} = doing |> task_fixture() |> Tasks.update_task(%{created_by_agent: name})
    end

    {:ok, _} =
      done
      |> task_fixture()
      |> Tasks.update_task(%{
        completed_by_agent: "Ada",
        status: :completed,
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
  end

  defp seed_target_with_bridged_goal(user, doing) do
    target = delivery_target_fixture(user, %{target_date: ~D[2026-07-21]})
    goal = task_fixture(doing, %{type: :goal})
    {:ok, _} = Tasks.update_task(goal, %{target_id: target.id})

    {:ok, _} =
      doing
      |> task_fixture()
      |> Tasks.update_task(%{created_by_agent: "Ada", parent_id: goal.id, status: :in_progress})
  end

  test "the disconnected first render defers the heavy data load", %{conn: conn, user: user} do
    seed_workspace(user)

    # A plain GET renders the LiveView with connected?(socket) == false — the
    # disconnected mount. It runs only the request's auth lookup and the board
    # selector query; the task-set fetches and the delivery rollup are deferred
    # to the connected mount. The pre-D120 load issued those reads here too
    # (~15+ queries), so a ceiling well below that trips if the deferral
    # regresses.
    static_queries = count_queries(fn -> get(conn, ~p"/agents") end)

    assert static_queries <= 6,
           "disconnected /agents render issued #{static_queries} queries — the heavy load " <>
             "should be deferred to the connected mount (expected <= 6)"
  end

  test "the connected mount still renders the full roster", %{conn: conn, user: user} do
    seed_workspace(user)

    {:ok, view, html} = live(conn, ~p"/agents")

    # Content is preserved: the connected mount loads the real data, so every
    # agent still appears and the delivery band still renders.
    assert has_element?(view, "[data-agent-roster-card]")
    assert html =~ "Ada"
    assert html =~ "Claude"
    assert html =~ "data-delivery-health-band"
  end

  # D125 root cause 2: an agent_event triggered a full load_agents_data/1 on
  # every message (debounced at @refresh_debounce_ms = 250). A burst of events
  # must coalesce into a SINGLE reload — the maybe_schedule_refresh/1 guard drops
  # every event after the first until the scheduled refresh fires. Counting Repo
  # queries over the settle window proves the burst did not fan out into one
  # reload per event.
  test "a burst of agent events coalesces into a single reload", %{conn: conn, user: user} do
    seed_workspace(user)
    {:ok, view, _html} = live(conn, ~p"/agents")

    one_reload =
      count_queries(fn ->
        send(view.pid, {:agent_event, %{}})
        Process.sleep(400)
        _ = render(view)
      end)

    burst =
      count_queries(fn ->
        for _ <- 1..5, do: send(view.pid, {:agent_event, %{}})
        Process.sleep(400)
        _ = render(view)
      end)

    # A single event reloads once (some queries).
    assert one_reload > 0

    # The 5-event burst debounces to one reload, so its query volume matches a
    # single reload — not ~5x. A small slack tolerates incidental variation; a
    # broken debounce (one reload per event) would be far above this ceiling.
    assert burst <= one_reload + 2,
           "a 5-event burst issued #{burst} queries vs #{one_reload} for one reload — " <>
             "the debounce should coalesce the burst into a single reload"
  end
end
