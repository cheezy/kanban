defmodule Kanban.Targets.DeliveryRollupQueryCountTest do
  @moduledoc """
  Regression guard for D125 root cause 3: `DeliveryRollup.build/2` fetched each
  target's member goals TWICE — once inside `list_targets_with_status/2` (for the
  status summary) and again directly in `target_rollup/4` — and this ran on every
  250ms /agents refresh. `list_targets_with_status_and_goals/2` now returns the
  member goals alongside each summary, so the member-goal query runs once per
  target.

  Measuring the per-target query DELTA (queries for two targets minus queries for
  one) cancels the fixed baseline (the bridged fetch, the target list) and
  isolates the per-target cost, which must not include a duplicate member-goal
  query.

  Not async — it attaches a global telemetry handler to the Repo query event, so
  concurrent tests' queries would otherwise pollute the count.
  """
  use Kanban.DataCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TargetsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Targets.DeliveryRollup
  alias Kanban.Tasks

  setup do
    user = user_fixture()
    board = board_fixture(user)
    doing = column_fixture(board, %{name: "Doing"})
    %{scope: Scope.for_user(user), doing: doing}
  end

  test "member goals are fetched once per target, not twice", %{scope: scope, doing: doing} do
    target1 = delivery_target_fixture(scope.user, %{name: "T1"})
    goal1 = goal_on_target(doing, target1)
    agent_task(doing, %{created_by_agent: "Ada", parent_id: goal1.id})

    one_target = count_queries(fn -> DeliveryRollup.build(scope) end)

    # A second target of the same shape (one member goal + one bridged task).
    target2 = delivery_target_fixture(scope.user, %{name: "T2"})
    goal2 = goal_on_target(doing, target2)
    agent_task(doing, %{created_by_agent: "Bea", parent_id: goal2.id})

    two_targets = count_queries(fn -> DeliveryRollup.build(scope) end)

    # After the dedup, the per-target delta is 3: the member-goal fetch (its main
    # query + a separate `:column` preload query) plus one child query for its
    # single goal. The pre-D125 double-fetch called `list_member_goals/2` a
    # second time per target, adding another main+preload pair (delta 5). The
    # `<= 4` ceiling sits between the two, catching the regression while
    # tolerating incidental single-query drift.
    assert two_targets - one_target <= 4,
           "adding a target added #{two_targets - one_target} queries — the duplicate " <>
             "member-goal fetch appears to have regressed (expected <= 4, deduped is 3)"
  end

  test "adding goals to a target does not add per-goal child queries (batched)",
       %{scope: scope, doing: doing} do
    target = delivery_target_fixture(scope.user, %{name: "T"})
    goal1 = goal_on_target(doing, target)
    agent_task(doing, %{created_by_agent: "Ada", parent_id: goal1.id})
    task_fixture(doing, %{parent_id: goal1.id})

    one_goal = count_queries(fn -> DeliveryRollup.build(scope) end)

    # Two more member goals on the SAME board, each with a child task. The child
    # tasks are fetched for all three goals in a single batched query per board
    # (member_goal_children/1), so the query count must not grow per goal.
    goal2 = goal_on_target(doing, target)
    goal3 = goal_on_target(doing, target)
    task_fixture(doing, %{parent_id: goal2.id})
    task_fixture(doing, %{parent_id: goal3.id})

    three_goals = count_queries(fn -> DeliveryRollup.build(scope) end)

    # Batched: the child fetch is one query per board regardless of goal count.
    # A per-goal N+1 would add ~2 queries per extra goal (delta ~4 for 2 goals).
    assert three_goals - one_goal <= 1,
           "adding 2 goals added #{three_goals - one_goal} queries — the per-goal child " <>
             "fetch is not batched (expected <= 1)"
  end

  # Counts the Repo query telemetry events emitted while `fun` runs.
  defp count_queries(fun) do
    ref = :counters.new(1, [])
    handler_id = "d125-rollup-qc-#{System.unique_integer([:positive])}"

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

  defp goal_on_target(column, target) do
    goal = task_fixture(column, %{type: :goal})
    {:ok, goal} = Tasks.update_task(goal, %{target_id: target.id})
    goal
  end

  defp agent_task(column, attrs) do
    {:ok, task} =
      column
      |> task_fixture()
      |> Tasks.update_task(Map.merge(%{status: :in_progress}, attrs))

    task
  end
end
