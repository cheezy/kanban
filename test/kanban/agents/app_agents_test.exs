defmodule Kanban.Agents.AppAgentsTest do
  @moduledoc "Tests for `Kanban.Agents.AppAgents` (W2761): the app's Agents tab."
  # async: false - one test switches the global :plans_enforced application env on.
  use Kanban.DataCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TasksFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Agents
  alias Kanban.Columns
  alias Kanban.Tasks

  setup do
    user = user_fixture()
    board = ai_optimized_board_fixture(user)
    %{user: user, scope: Scope.for_user(user), board: board, cols: columns(board)}
  end

  defp columns(board), do: board |> Columns.list_columns() |> Map.new(&{&1.name, &1})

  defp agent_task(column, attrs \\ %{}),
    do: task_fixture(column, Map.merge(%{created_by_agent: "Claude"}, attrs))

  defp complete!(task) do
    {:ok, task} =
      Tasks.update_task(task, %{"status" => "completed", "completed_at" => DateTime.utc_now()})

    task
  end

  defp archive!(task) do
    task |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second)) |> Repo.update!()
  end

  defp entry(overview, goal), do: Enum.find(overview.goals, &(&1.goal.id == goal.id))

  test "returns the roster and the open goals its agents work on", ctx do
    goal = task_fixture(ctx.cols["Backlog"], %{type: :goal})
    agent_task(ctx.cols["Doing"], %{parent_id: goal.id})
    task_fixture(ctx.cols["Ready"], %{parent_id: goal.id})

    quiet_goal = task_fixture(ctx.cols["Backlog"], %{type: :goal})
    task_fixture(ctx.cols["Ready"], %{parent_id: quiet_goal.id})
    agent_task(ctx.cols["Done"], %{parent_id: quiet_goal.id}) |> complete!()

    overview = Agents.list_agents_for_app(ctx.scope)

    assert [%Agents.Agent{name: "Claude", status: :working}] = overview.agents
    assert [%{goal: %{id: id}, board_id: board_id}] = overview.goals
    assert id == goal.id
    assert board_id == ctx.board.id
  end

  test "a goal's counts are its own tasks, never the goal itself", ctx do
    goal = task_fixture(ctx.cols["Backlog"], %{type: :goal})
    agent_task(ctx.cols["Doing"], %{parent_id: goal.id})
    agent_task(ctx.cols["Review"], %{parent_id: goal.id})
    task_fixture(ctx.cols["Done"], %{parent_id: goal.id}) |> complete!()
    task_fixture(ctx.cols["Ready"], %{parent_id: goal.id, status: :blocked})

    tree = Kanban.Tasks.Goals.get_task_tree(goal.id, ctx.board.id)
    assert tree.counts.total == 5

    assert entry(Agents.list_agents_for_app(ctx.scope), goal).counts ==
             %{total: 4, completed: 1, doing: 1, review: 1, blocked: 1}
  end

  test "archived tasks count as the /agents goal rows count them (D124)", ctx do
    goal = task_fixture(ctx.cols["Backlog"], %{type: :goal})
    agent_task(ctx.cols["Doing"], %{parent_id: goal.id})
    task_fixture(ctx.cols["Done"], %{parent_id: goal.id}) |> complete!() |> archive!()
    task_fixture(ctx.cols["Ready"], %{parent_id: goal.id}) |> archive!()

    assert entry(Agents.list_agents_for_app(ctx.scope), goal).counts ==
             %{total: 2, completed: 1, doing: 1, review: 0, blocked: 0}
  end

  test "an archived task left in Doing or Review does not keep its goal on the list", ctx do
    removed = task_fixture(ctx.cols["Backlog"], %{type: :goal})
    agent_task(ctx.cols["Doing"], %{parent_id: removed.id}) |> archive!()
    agent_task(ctx.cols["Review"], %{parent_id: removed.id}) |> archive!()

    worked = task_fixture(ctx.cols["Backlog"], %{type: :goal})
    agent_task(ctx.cols["Review"], %{parent_id: worked.id})
    agent_task(ctx.cols["Doing"], %{parent_id: worked.id}) |> archive!()

    overview = Agents.list_agents_for_app(ctx.scope)

    assert Enum.map(overview.goals, & &1.goal.id) == [worked.id]

    assert entry(overview, worked).counts == %{
             total: 1,
             completed: 0,
             doing: 0,
             review: 1,
             blocked: 0
           }
  end

  test "completed and archived goals, and goals no agent works on, are left out", ctx do
    # Completed after its task is added, which would otherwise reopen it.
    done = task_fixture(ctx.cols["Done"], %{type: :goal})
    agent_task(ctx.cols["Review"], %{parent_id: done.id})
    done |> Ecto.Changeset.change(status: :completed) |> Repo.update!()

    archived = task_fixture(ctx.cols["Backlog"], %{type: :goal}) |> archive!()
    agent_task(ctx.cols["Doing"], %{parent_id: archived.id})

    unattended = task_fixture(ctx.cols["Backlog"], %{type: :goal})
    task_fixture(ctx.cols["Doing"], %{parent_id: unattended.id})

    assert Agents.list_agents_for_app(ctx.scope).goals == []
  end

  test "flags a goal whose last after_goal attempt failed", ctx do
    goal =
      ctx.cols["Backlog"]
      |> task_fixture(%{type: :goal})
      |> Ecto.Changeset.change(
        after_goal_status: :pending,
        after_goal_result: %{"exit_code" => 1}
      )
      |> Repo.update!()

    other = task_fixture(ctx.cols["Backlog"], %{type: :goal})
    agent_task(ctx.cols["Doing"], %{parent_id: goal.id})
    agent_task(ctx.cols["Doing"], %{parent_id: other.id})

    overview = Agents.list_agents_for_app(ctx.scope)
    assert entry(overview, goal).hook_failed
    refute entry(overview, other).hook_failed
  end

  test "an agent on two boards is one agent", ctx do
    second = ai_optimized_board_fixture(ctx.user)
    agent_task(ctx.cols["Doing"])
    agent_task(columns(second)["Review"])

    assert [%Agents.Agent{name: "Claude"}] = Agents.list_agents_for_app(ctx.scope).agents
  end

  test "only boards the person can see contribute", ctx do
    stranger = user_fixture()
    foreign = ai_optimized_board_fixture(stranger)
    foreign_goal = task_fixture(columns(foreign)["Backlog"], %{type: :goal})

    agent_task(columns(foreign)["Doing"], %{created_by_agent: "Codex", parent_id: foreign_goal.id})

    assert Agents.list_agents_for_app(ctx.scope) == %{agents: [], goals: []}
    assert Agents.list_agents_for_app(nil) == %{agents: [], goals: []}
    assert Agents.list_agents_for_app(%Scope{user: nil}) == %{agents: [], goals: []}
  end

  test "boards outside the plan are left out while plans are enforced", ctx do
    enforce_plans()
    goal = task_fixture(ctx.cols["Backlog"], %{type: :goal})
    agent_task(ctx.cols["Doing"], %{parent_id: goal.id})

    assert Agents.list_agents_for_app(ctx.scope) == %{agents: [], goals: []}

    organization = organization_fixture()
    organization_member_fixture(organization, ctx.user)
    workspace = org_workspace_fixture(organization)
    workspace_member_fixture(workspace, ctx.user)
    ctx.board |> Ecto.Changeset.change(workspace_id: workspace.id) |> Repo.update!()

    assert %{agents: [_agent], goals: [_goal]} = Agents.list_agents_for_app(ctx.scope)
  end

  test "counts today's work in the given time zone, else UTC", ctx do
    at = :second |> DateTime.utc_now() |> DateTime.add(-12, :hour)

    {:ok, _task} =
      agent_task(ctx.cols["Done"])
      |> Tasks.update_task(%{"status" => "completed", "completed_at" => at})

    # Twelve hours ago is "today" in exactly one of two zones twelve hours apart.
    {today_zone, other_zone} = split_zones(at)

    assert [%{today: 1}] = Agents.list_agents_for_app(ctx.scope, timezone: today_zone).agents
    assert [%{today: 0}] = Agents.list_agents_for_app(ctx.scope, timezone: other_zone).agents

    utc_today = if today_zone == "Etc/UTC", do: 1, else: 0
    assert [%{today: ^utc_today}] = Agents.list_agents_for_app(ctx.scope, timezone: nil).agents
    assert [%{today: ^utc_today}] = Agents.list_agents_for_app(ctx.scope).agents
  end

  defp split_zones(at) do
    if Kanban.Timezone.local_date(at, "Etc/UTC") == Kanban.Timezone.local_today("Etc/UTC"),
      do: {"Etc/UTC", "Etc/GMT-12"},
      else: {"Etc/GMT-12", "Etc/UTC"}
  end
end
