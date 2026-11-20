defmodule Kanban.Targets.AppTargetsTest do
  @moduledoc """
  Unit tests for `Kanban.Targets.AppTargets`, the app's Targets list and
  Target screen (W2763). The controller tests cover the routes; these pin the
  rules with an injected `now`.
  """
  use Kanban.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TargetsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Agents.Agent
  alias Kanban.Repo
  alias Kanban.Targets.AppTargets
  alias Kanban.Targets.DeliveryTarget
  alias Kanban.Tasks

  setup do
    user = user_fixture()
    board = board_fixture(user)
    doing = column_fixture(board, %{name: "Doing"})
    %{user: user, scope: Scope.for_user(user), doing: doing}
  end

  defp goal_on_target(column, target) do
    goal = task_fixture(column, %{type: :goal})
    {:ok, goal} = Tasks.update_task(goal, %{target_id: target.id})
    goal
  end

  # 4 children completed at an exact 1-day lead + 1 open: the estimate is one
  # day after `now`, as in the rollup's own slip test.
  defp slipping_goal!(column, target) do
    goal = goal_on_target(column, target)

    for _ <- 1..4 do
      column
      |> task_fixture(%{parent_id: goal.id})
      |> Ecto.Changeset.change(
        status: :completed,
        completed_at: ~U[2026-07-01 12:00:00Z],
        inserted_at: ~N[2026-06-30 12:00:00]
      )
      |> Repo.update!()
    end

    task_fixture(column, %{parent_id: goal.id})
    goal
  end

  describe "list/2" do
    test "a scope with no user lists nothing" do
      assert AppTargets.list(nil) == []
      assert AppTargets.list(%Scope{user: nil}) == []
    end

    test "rows carry the rollup's status, estimate and counts", %{scope: scope, doing: doing} do
      target = delivery_target_fixture(scope.user, %{target_date: ~D[2026-07-26]})
      slipping_goal!(doing, target)

      assert [row] = AppTargets.list(scope, now: ~U[2026-07-26 00:00:00Z])

      assert %{
               status: :at_risk,
               estimated_completion_date: ~D[2026-07-27],
               goal_count: 1,
               completed: 4,
               total: 5,
               owner: true
             } = row

      assert row.target.id == target.id
    end
  end

  describe "detail/3" do
    test "a slipped estimate gives slipped risk", %{scope: scope, doing: doing} do
      target = delivery_target_fixture(scope.user, %{target_date: ~D[2026-07-26]})
      slipping_goal!(doing, target)

      assert {:ok, detail} = AppTargets.detail(scope, target.id, now: ~U[2026-07-26 00:00:00Z])

      assert detail.target.status == :at_risk

      assert detail.risk == %{
               slipped: %{estimate: ~D[2026-07-27], target_date: ~D[2026-07-26]},
               stalled: []
             }
    end

    test "an archived target takes its status from its progress", %{scope: scope, doing: doing} do
      target = delivery_target_fixture(scope.user)
      goal_on_target(doing, target)

      from(t in DeliveryTarget, where: t.id == ^target.id)
      |> Repo.update_all(set: [archived_at: DateTime.utc_now()])

      progress = Kanban.Targets.get_target_progress(scope, target, ~U[2026-07-01 00:00:00Z])

      assert {:ok, detail} = AppTargets.detail(scope, target.id, now: ~U[2026-07-01 00:00:00Z])
      assert detail.target.status == progress.summary.status
      assert detail.target.goal_count == 1
      assert detail.risk == nil
    end

    test "is owner only", %{scope: scope, doing: doing} do
      theirs = delivery_target_fixture(user_fixture())
      goal_on_target(doing, theirs)

      assert AppTargets.detail(scope, theirs.id) == {:error, :not_found}
      assert AppTargets.detail(nil, theirs.id) == {:error, :not_found}
    end
  end

  describe "risk/4" do
    @stalled [%{goal: :goal, agents: [%{name: "Ada", reasons: [:stuck]}]}]

    test "only an at-risk target with a reason has one" do
      assert AppTargets.risk(:at_risk, nil, ~D[2026-07-26], []) == nil
      assert AppTargets.risk(:at_risk, ~D[2026-07-20], ~D[2026-07-26], []) == nil

      assert AppTargets.risk(:at_risk, nil, ~D[2026-07-26], @stalled) == %{
               slipped: nil,
               stalled: @stalled
             }

      for status <- [:on_track, :missed, :complete] do
        assert AppTargets.risk(status, ~D[2026-08-01], ~D[2026-07-26], @stalled) == nil
      end
    end

    test "gives both reasons together" do
      assert AppTargets.risk(:at_risk, ~D[2026-08-01], ~D[2026-07-26], @stalled) == %{
               slipped: %{estimate: ~D[2026-08-01], target_date: ~D[2026-07-26]},
               stalled: @stalled
             }
    end
  end

  describe "reasons/1" do
    test "names stuck before dormant" do
      assert AppTargets.reasons(%Agent{stuck: true, dormant: true}) == [:stuck, :dormant]
      assert AppTargets.reasons(%Agent{stuck: false, dormant: true}) == [:dormant]
      assert AppTargets.reasons(%Agent{stuck: true, dormant: false}) == [:stuck]
      assert AppTargets.reasons(%Agent{stuck: false, dormant: false}) == []
    end
  end
end
