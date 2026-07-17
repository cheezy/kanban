defmodule Kanban.Agents.SharedFetchQueryCountTest do
  @moduledoc """
  Proves the W1242 optimization: deriving every Agents-view metric from a single
  shared task fetch issues far fewer DB queries than the old path where each
  metric independently re-ran `Agents.fetch_tasks/1`.

  Not async — it attaches a global telemetry handler to the Repo query event.
  """
  use Kanban.DataCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Agents
  alias Kanban.Tasks

  setup do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, _} =
      column
      |> task_fixture()
      |> Tasks.update_task(%{
        created_by_agent: "Claude",
        completed_by_agent: "Claude",
        claimed_at: now,
        completed_at: now,
        status: :completed,
        time_spent_minutes: 30
      })

    {:ok, _} =
      column
      |> task_fixture()
      |> Tasks.update_task(%{created_by_agent: "Codex", claimed_at: now, status: :in_progress})

    %{scope: Scope.for_user(user)}
  end

  # Counts the Repo query telemetry events emitted while `fun` runs.
  defp count_queries(fun) do
    ref = :counters.new(1, [])
    handler_id = "qc-#{System.unique_integer([:positive])}"

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

  # The pre-W1242 render path: each metric re-fetched the full task set.
  defp keyword_path(scope) do
    Agents.list_agents(scope: scope)
    Agents.recent_activity(scope: scope, limit: 200)
    Agents.header_stats(scope: scope)
    Agents.fleet_health(scope: scope)
    Agents.throughput_and_success(scope: scope)
    Agents.throughput_trends(scope: scope)
    Agents.agent_detail("Claude", scope: scope)
  end

  # The W1242 render path: fetch once, derive everything from the shared list.
  defp shared_path(scope) do
    tasks = Agents.fetch_tasks(scope: scope)
    agents = Agents.list_agents_from(tasks)
    Agents.recent_activity_from(tasks, 200)
    Agents.header_stats_from(tasks)
    Agents.fleet_health_from(agents)
    Agents.throughput_and_success_from(tasks)
    Agents.throughput_trends_from(tasks)
    Agents.agent_detail_from(tasks, "Claude")
  end

  test "the shared-fetch path issues far fewer queries than the per-metric path", %{scope: scope} do
    # Warm up so the parity between the two paths is measured, not first-call noise.
    keyword_path(scope)
    shared_path(scope)

    keyword_queries = count_queries(fn -> keyword_path(scope) end)
    shared_queries = count_queries(fn -> shared_path(scope) end)

    # The old path re-fetches the task set for each of the 7 consumers. Since the
    # W1733 projection each fetch is now a SINGLE joined SELECT (no main-SELECT +
    # 3 preload batches), so the per-metric path issues about one query per
    # consumer instead of ~4 — still far more than the shared path.
    assert keyword_queries >= 7

    # The new path fetches once (one projected SELECT) and every derivation reuses
    # that in-memory list with no further queries.
    assert shared_queries <= 3
    assert shared_queries < keyword_queries
  end
end
