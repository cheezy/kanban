defmodule Kanban.AgentsTest do
  use Kanban.DataCase

  import Ecto.Query, only: [from: 2]
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Agents
  alias Kanban.Agents.Agent
  alias Kanban.Agents.Event
  alias Kanban.Tasks

  setup do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board)
    %{user: user, board: board, column: column}
  end

  describe "list_agents/1" do
    test "returns an empty list when no tasks exist" do
      assert Agents.list_agents() == []
    end

    test "returns distinct non-nil agent names across created_by_agent and completed_by_agent",
         %{column: column} do
      {:ok, _} = column |> task_fixture() |> Tasks.update_task(%{created_by_agent: "Claude"})
      {:ok, _} = column |> task_fixture() |> Tasks.update_task(%{created_by_agent: "Claude"})
      {:ok, _} = column |> task_fixture() |> Tasks.update_task(%{completed_by_agent: "Codex"})
      _bare = task_fixture(column)

      # Ordering is asserted separately; here we only care about the set of
      # distinct names, so compare order-independently.
      names = Agents.list_agents() |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["Claude", "Codex"]
    end

    test "orders agents by most recent activity, newest first", %{column: column} do
      recent = DateTime.utc_now() |> DateTime.truncate(:second)
      older = DateTime.add(recent, -3600, :second)

      # "Zoe" is alphabetically last but most recently active, so a recency
      # ordering must place her above "Adam" — proving it is not alphabetical.
      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Adam", claimed_at: older})

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Zoe", claimed_at: recent})

      names = Agents.list_agents() |> Enum.map(& &1.name)
      assert names == ["Zoe", "Adam"]
    end

    test "breaks recency ties alphabetically by name", %{column: column} do
      at = DateTime.utc_now() |> DateTime.truncate(:second)

      # Both agents derive their recency from the same task timestamp, so the
      # tie must break on name for a stable, non-flaky order.
      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Zeta",
          completed_by_agent: "Alpha",
          completed_at: at,
          status: :completed
        })

      names = Agents.list_agents() |> Enum.map(& &1.name)
      assert names == ["Alpha", "Zeta"]
    end

    test "sorts an agent whose only timestamp is task creation to the bottom",
         %{column: column} do
      {:ok, idle} =
        column |> task_fixture() |> Tasks.update_task(%{created_by_agent: "Idle"})

      # Backdate the idle agent's only timestamp (task creation) well into the
      # past so it is unambiguously older than the active agent's activity.
      backdate_query = from(t in Kanban.Tasks.Task, where: t.id == ^idle.id)
      Repo.update_all(backdate_query, set: [inserted_at: ~N[2020-01-01 00:00:00]])

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Active",
          completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          status: :completed
        })

      names = Agents.list_agents() |> Enum.map(& &1.name)
      assert names == ["Active", "Idle"]
    end

    test "infers :working when the agent has an in-progress task", %{column: column} do
      {:ok, task} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Claude", status: :in_progress})

      [%Agent{name: "Claude", status: :working, current_task: current}] = Agents.list_agents()

      assert current == %{identifier: task.identifier, title: task.title}
    end

    test "infers :waiting when the most-recent task is completed and awaiting review",
         %{column: column} do
      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          completed_by_agent: "Claude",
          completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          status: :completed,
          needs_review: true
        })

      [%Agent{name: "Claude", status: :waiting, current_task: nil}] = Agents.list_agents()
    end

    test "infers :idle otherwise", %{column: column, user: user} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          completed_by_agent: "Claude",
          completed_at: now,
          status: :completed,
          needs_review: true,
          reviewed_at: now,
          reviewed_by_id: user.id,
          review_status: :approved
        })

      [%Agent{name: "Claude", status: :idle}] = Agents.list_agents()
    end

    test "scope filters to boards the user can access", %{column: column} do
      {:ok, _} = column |> task_fixture() |> Tasks.update_task(%{created_by_agent: "Claude"})

      other_user = user_fixture()
      scope = Scope.for_user(other_user)

      assert Agents.list_agents(scope: scope) == []
    end

    test "a task with distinct created_by_agent and completed_by_agent emits two agents",
         %{column: column} do
      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          completed_by_agent: "Codex",
          completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          status: :completed
        })

      agents = Agents.list_agents()
      names = Enum.map(agents, & &1.name)
      assert names == ["Claude", "Codex"]

      Enum.each(agents, fn agent ->
        assert agent.today == 1
      end)
    end
  end

  describe "recent_activity/1" do
    test "returns an empty list when no tasks exist" do
      assert Agents.recent_activity() == []
    end

    test "emits :create, :claim, :complete, and :review events from task timestamps",
         %{column: column, user: user} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          completed_by_agent: "Claude",
          claimed_at: now,
          completed_at: now,
          reviewed_at: now,
          reviewed_by_id: user.id,
          review_status: :approved
        })

      kinds = Agents.recent_activity() |> Enum.map(& &1.kind) |> Enum.sort()
      assert kinds == [:claim, :complete, :create, :review]
    end

    test "the :claim event actor is the completing agent, falling back to the creator (D82)",
         %{column: column} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # Completed task: the claim actor is the agent that worked/completed it.
      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Creator",
          completed_by_agent: "Worker",
          claimed_at: now,
          completed_at: now
        })

      claim = Agents.recent_activity() |> Enum.find(&(&1.kind == :claim))
      assert claim.actor == "Worker"
    end

    test "the :claim event actor falls back to the creating agent when not yet completed (D82)",
         %{column: column} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Creator", claimed_at: now})

      claim = Agents.recent_activity() |> Enum.find(&(&1.kind == :claim))
      assert claim.actor == "Creator"
    end

    test "respects the :limit option", %{column: column} do
      Enum.each(1..10, fn _ -> task_fixture(column) end)

      assert Agents.recent_activity(limit: 3) |> length() == 3
    end

    test "events are sorted by :at descending", %{column: column} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      earlier = DateTime.add(now, -3600, :second)

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{claimed_at: earlier, completed_at: now})

      [first | rest] = Agents.recent_activity()

      Enum.each(rest, fn event ->
        assert DateTime.compare(first.at, event.at) in [:gt, :eq]
      end)
    end

    test "attaches cycle_time_minutes only to :complete events", %{column: column} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          completed_by_agent: "Claude",
          claimed_at: now,
          completed_at: now,
          time_spent_minutes: 42
        })

      events = Agents.recent_activity()
      complete = Enum.find(events, &(&1.kind == :complete))
      claim = Enum.find(events, &(&1.kind == :claim))

      assert complete.cycle_time_minutes == 42
      assert claim.cycle_time_minutes == nil
    end

    test "returns %Event{} structs", %{column: column} do
      task_fixture(column)
      assert [%Event{} | _] = Agents.recent_activity()
    end

    test "scope filters events to boards the user can access", %{column: column} do
      task_fixture(column)
      other_scope = Scope.for_user(user_fixture())

      assert Agents.recent_activity(scope: other_scope) == []
    end
  end

  describe "header_stats/1" do
    test "returns zeros when no tasks exist" do
      assert Agents.header_stats() == %{
               claimed_today: 0,
               completed_today: 0,
               approved_today: 0,
               avg_cycle_minutes: 0.0
             }
    end

    test "counts claimed_today, completed_today, approved_today against today",
         %{column: column, user: user} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          claimed_at: now,
          completed_at: now,
          reviewed_at: now,
          reviewed_by_id: user.id,
          review_status: :approved
        })

      stats = Agents.header_stats()
      assert stats.claimed_today == 1
      assert stats.completed_today == 1
      assert stats.approved_today == 1
    end

    test "excludes rejected reviews from approved_today", %{column: column, user: user} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          reviewed_at: now,
          reviewed_by_id: user.id,
          review_status: :rejected
        })

      assert Agents.header_stats().approved_today == 0
    end

    test "computes avg_cycle_minutes from time_spent_minutes on completed tasks",
         %{column: column} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{completed_at: now, time_spent_minutes: 30})

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{completed_at: now, time_spent_minutes: 90})

      assert Agents.header_stats().avg_cycle_minutes == 60.0
    end

    test "excludes completed tasks with nil time_spent_minutes from avg_cycle", %{column: column} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{completed_at: now, time_spent_minutes: nil})

      assert Agents.header_stats().avg_cycle_minutes == 0.0
    end

    test "scope isolates header stats to the requested user", %{column: column, user: user} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          claimed_at: now,
          completed_at: now,
          reviewed_at: now,
          reviewed_by_id: user.id,
          review_status: :approved
        })

      assert Agents.header_stats(scope: Scope.for_user(user)) == %{
               claimed_today: 1,
               completed_today: 1,
               approved_today: 1,
               avg_cycle_minutes: 0.0
             }

      assert Agents.header_stats(scope: Scope.for_user(user_fixture())) == %{
               claimed_today: 0,
               completed_today: 0,
               approved_today: 0,
               avg_cycle_minutes: 0.0
             }
    end
  end
end
