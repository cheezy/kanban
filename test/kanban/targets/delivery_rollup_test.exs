defmodule Kanban.Targets.DeliveryRollupTest do
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
  alias Kanban.Targets.DeliveryRollup
  alias Kanban.Targets.DeliveryTarget
  alias Kanban.Tasks

  setup do
    user = user_fixture()
    board = board_fixture(user)
    doing = column_fixture(board, %{name: "Doing"})
    %{user: user, scope: Scope.for_user(user), board: board, doing: doing}
  end

  describe "build/2 — agent-to-target attribution" do
    test "a goal's agent is attributed to that goal's target", %{scope: scope, doing: doing} do
      target = delivery_target_fixture(scope.user)
      goal = goal_on_target(doing, target)
      agent_task(doing, %{created_by_agent: "Ada", parent_id: goal.id, claimed_at: ago(5)})

      rollup = DeliveryRollup.build(scope)

      assert [entry] = rollup.targets
      assert entry.target.id == target.id
      assert Enum.map(entry.goals, & &1.id) == [goal.id]
      assert [%Agent{name: "Ada"}] = entry.agents
      assert entry.stalled_agents == []
      assert entry.stalled_goals == []
      assert rollup.unrolled_agents == []
    end

    test "an agent active on two targets appears under both", %{scope: scope, doing: doing} do
      target_a = delivery_target_fixture(scope.user, %{name: "A"})
      target_b = delivery_target_fixture(scope.user, %{name: "B"})
      goal_a = goal_on_target(doing, target_a)
      goal_b = goal_on_target(doing, target_b)
      agent_task(doing, %{created_by_agent: "Ada", parent_id: goal_a.id, claimed_at: ago(5)})
      agent_task(doing, %{created_by_agent: "Ada", parent_id: goal_b.id, claimed_at: ago(5)})

      rollup = DeliveryRollup.build(scope)

      for entry <- rollup.targets do
        assert [%Agent{name: "Ada"}] = entry.agents
      end

      assert rollup.unrolled_agents == []
    end
  end

  describe "build/2 — agents outside the rollup" do
    test "an agent whose task has no goal parent is grouped outside the rollup",
         %{scope: scope, doing: doing} do
      agent_task(doing, %{created_by_agent: "Orphan", claimed_at: ago(5)})

      rollup = DeliveryRollup.build(scope)

      assert rollup.targets == []
      assert [%Agent{name: "Orphan"}] = rollup.unrolled_agents
    end

    test "an agent whose parent goal has no target is grouped outside the rollup",
         %{scope: scope, doing: doing} do
      goal = task_fixture(doing, %{type: :goal})
      agent_task(doing, %{created_by_agent: "Ada", parent_id: goal.id, claimed_at: ago(5)})

      rollup = DeliveryRollup.build(scope)

      assert rollup.targets == []
      assert [%Agent{name: "Ada"}] = rollup.unrolled_agents
    end

    test "a target agent is not also listed as unrolled", %{scope: scope, doing: doing} do
      target = delivery_target_fixture(scope.user)
      goal = goal_on_target(doing, target)
      agent_task(doing, %{created_by_agent: "Ada", parent_id: goal.id, claimed_at: ago(5)})
      agent_task(doing, %{created_by_agent: "Orphan", claimed_at: ago(5)})

      rollup = DeliveryRollup.build(scope)

      assert [%Agent{name: "Ada"}] = hd(rollup.targets).agents
      assert [%Agent{name: "Orphan"}] = rollup.unrolled_agents
    end
  end

  describe "build/2 — stalled goals and agents" do
    test "a stalled agent surfaces under the correct at-risk target", %{
      scope: scope,
      doing: doing
    } do
      today = ~D[2026-07-01]

      # At-risk target: created 80 days before `today`, due 20 days after, with
      # no completed work — elapsed calendar (0.8) far outruns work share (0.0).
      at_risk =
        delivery_target_fixture(scope.user, %{name: "AtRisk", target_date: ~D[2026-07-21]})

      backdate_target(at_risk, ~N[2026-04-12 00:00:00])
      at_risk_goal = goal_on_target(doing, at_risk)
      # Stuck: active in Doing, last touched 90 minutes ago (> 60m threshold).
      agent_task(doing, %{
        created_by_agent: "Stalled",
        parent_id: at_risk_goal.id,
        claimed_at: ago(90)
      })

      # A healthy on-track target with a fresh agent, to prove correct routing.
      on_track =
        delivery_target_fixture(scope.user, %{name: "OnTrack", target_date: ~D[2026-12-31]})

      on_track_goal = goal_on_target(doing, on_track)

      agent_task(doing, %{
        created_by_agent: "Fresh",
        parent_id: on_track_goal.id,
        claimed_at: ago(5)
      })

      rollup = DeliveryRollup.build(scope, today: today)

      at_risk_entry = Enum.find(rollup.targets, &(&1.target.id == at_risk.id))
      on_track_entry = Enum.find(rollup.targets, &(&1.target.id == on_track.id))

      assert at_risk_entry.status == :at_risk
      assert [%Agent{name: "Stalled", stuck: true}] = at_risk_entry.stalled_agents
      assert Enum.map(at_risk_entry.stalled_goals, & &1.id) == [at_risk_goal.id]

      assert on_track_entry.status == :on_track
      assert on_track_entry.stalled_agents == []
      assert on_track_entry.stalled_goals == []
    end

    test "stalled_details pairs each stalled goal with the stalled agents on it",
         %{scope: scope, doing: doing} do
      target = delivery_target_fixture(scope.user)
      goal_a = goal_on_target(doing, target)
      goal_b = goal_on_target(doing, target)

      # Stuck agent on goal_a; a different stuck agent on goal_b; a healthy
      # agent on goal_a that must NOT appear in the stalled details.
      agent_task(doing, %{created_by_agent: "StalledA", parent_id: goal_a.id, claimed_at: ago(90)})

      agent_task(doing, %{created_by_agent: "StalledB", parent_id: goal_b.id, claimed_at: ago(90)})

      agent_task(doing, %{created_by_agent: "Fresh", parent_id: goal_a.id, claimed_at: ago(5)})

      [entry] = DeliveryRollup.build(scope).targets

      details = Map.new(entry.stalled_details, fn d -> {d.goal.id, agent_names(d.agents)} end)

      assert details[goal_a.id] == ["StalledA"]
      assert details[goal_b.id] == ["StalledB"]
      # Every stalled goal appears exactly once in the details.
      assert length(entry.stalled_details) == 2
    end

    test "stalled_details is empty when no agent is stalled", %{scope: scope, doing: doing} do
      target = delivery_target_fixture(scope.user)
      goal = goal_on_target(doing, target)
      agent_task(doing, %{created_by_agent: "Ada", parent_id: goal.id, claimed_at: ago(5)})

      [entry] = DeliveryRollup.build(scope).targets

      assert entry.stalled_details == []
    end

    test "a dormant agent counts as stalled", %{scope: scope, board: board} do
      done = column_fixture(board, %{name: "Done"})
      target = delivery_target_fixture(scope.user)
      goal = goal_on_target(done, target)

      task =
        agent_task(done, %{
          created_by_agent: "Sleepy",
          parent_id: goal.id,
          status: :completed,
          completed_at: ~U[2026-01-01 00:00:00Z]
        })

      backdate_updated_at(task, ~N[2026-01-01 00:00:00])

      rollup = DeliveryRollup.build(scope)
      [entry] = rollup.targets

      assert [%Agent{name: "Sleepy", dormant: true}] = entry.stalled_agents
      assert Enum.map(entry.stalled_goals, & &1.id) == [goal.id]
    end

    test "a healthy agent does not stall its goal", %{scope: scope, doing: doing} do
      target = delivery_target_fixture(scope.user)
      goal = goal_on_target(doing, target)
      agent_task(doing, %{created_by_agent: "Ada", parent_id: goal.id, claimed_at: ago(5)})

      [entry] = DeliveryRollup.build(scope).targets

      assert [%Agent{name: "Ada"}] = entry.agents
      assert entry.stalled_agents == []
      assert entry.stalled_goals == []
    end
  end

  describe "build/2 — board scoping" do
    test "targets and goals on inaccessible boards are excluded", %{scope: scope, doing: doing} do
      # Accessible: our own target with an agent.
      mine = delivery_target_fixture(scope.user)
      my_goal = goal_on_target(doing, mine)
      agent_task(doing, %{created_by_agent: "Mine", parent_id: my_goal.id, claimed_at: ago(5)})

      # Inaccessible: a foreign user's board, target, goal, and agent.
      other = user_fixture()
      other_doing = other |> board_fixture() |> column_fixture(%{name: "Doing"})
      foreign = delivery_target_fixture(other)
      foreign_goal = goal_on_target(other_doing, foreign)

      agent_task(other_doing, %{
        created_by_agent: "Foreign",
        parent_id: foreign_goal.id,
        claimed_at: ago(5)
      })

      rollup = DeliveryRollup.build(scope)

      assert [entry] = rollup.targets
      assert entry.target.id == mine.id
      assert [%Agent{name: "Mine"}] = entry.agents
      refute Enum.any?(rollup.targets, &(&1.target.id == foreign.id))
      refute Enum.any?(rollup.unrolled_agents, &(&1.name == "Foreign"))
    end
  end

  describe "build/2 — shape and defaults" do
    test "an empty board yields no targets and no unrolled agents", %{scope: scope} do
      assert DeliveryRollup.build(scope) == %{
               targets: [],
               unrolled_agents: [],
               agent_targets: %{}
             }
    end

    test "each target entry carries every rollup field", %{scope: scope, doing: doing} do
      target = delivery_target_fixture(scope.user)
      goal = goal_on_target(doing, target)
      agent_task(doing, %{created_by_agent: "Ada", parent_id: goal.id, claimed_at: ago(5)})

      [entry] = DeliveryRollup.build(scope).targets

      assert %{
               target: %DeliveryTarget{},
               status: status,
               goals: [_ | _],
               agents: [_ | _],
               stalled_goals: [],
               stalled_agents: []
             } = entry

      assert status in [:complete, :missed, :at_risk, :on_track]
    end
  end

  describe "build/2 — agent_targets annotation" do
    test "annotates an agent with the target and goal it advances", %{scope: scope, doing: doing} do
      target = delivery_target_fixture(scope.user, %{name: "Launch"})
      goal = goal_on_target(doing, target)
      {:ok, goal} = Tasks.update_task(goal, %{title: "Ship the API"})
      agent_task(doing, %{created_by_agent: "Ada", parent_id: goal.id, claimed_at: ago(5)})

      rollup = DeliveryRollup.build(scope)

      assert [%{target: t, goal: g, status: status}] = rollup.agent_targets[{"Ada", "none"}]
      assert t.id == target.id
      assert g.id == goal.id
      assert status == :on_track
    end

    test "an agent with no target has an empty annotation list", %{scope: scope, doing: doing} do
      agent_task(doing, %{created_by_agent: "Orphan", claimed_at: ago(5)})

      rollup = DeliveryRollup.build(scope)

      assert rollup.agent_targets[{"Orphan", "none"}] == []
    end

    test "annotates an agent advancing goals on two targets", %{scope: scope, doing: doing} do
      target_a = delivery_target_fixture(scope.user, %{name: "A"})
      target_b = delivery_target_fixture(scope.user, %{name: "B"})
      goal_a = goal_on_target(doing, target_a)
      goal_b = goal_on_target(doing, target_b)
      agent_task(doing, %{created_by_agent: "Ada", parent_id: goal_a.id, claimed_at: ago(5)})
      agent_task(doing, %{created_by_agent: "Ada", parent_id: goal_b.id, claimed_at: ago(5)})

      rollup = DeliveryRollup.build(scope)

      target_ids =
        rollup.agent_targets[{"Ada", "none"}] |> Enum.map(& &1.target.id) |> Enum.sort()

      assert target_ids == Enum.sort([target_a.id, target_b.id])
    end
  end

  # --- helpers ---------------------------------------------------------------

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

  defp agent_names(agents), do: agents |> Enum.map(& &1.name) |> Enum.sort()

  defp ago(minutes) do
    DateTime.utc_now() |> DateTime.add(-minutes * 60, :second) |> DateTime.truncate(:second)
  end

  defp backdate_target(%DeliveryTarget{id: id}, %NaiveDateTime{} = at) do
    from(t in DeliveryTarget, where: t.id == ^id)
    |> Repo.update_all(set: [inserted_at: at])
  end

  defp backdate_updated_at(%{id: id}, %NaiveDateTime{} = at) do
    from(t in Kanban.Tasks.Task, where: t.id == ^id)
    |> Repo.update_all(set: [updated_at: at])
  end
end
