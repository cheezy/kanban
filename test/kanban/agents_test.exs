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

  describe "fetch_tasks/1 board and time-range filtering" do
    setup %{user: user} do
      %{scope: Scope.for_user(user)}
    end

    test "without board_id or time_range returns the scope-only set (back-compat)",
         %{column: column, scope: scope} do
      task_fixture(column)
      assert length(Agents.fetch_tasks(scope: scope)) == 1
    end

    test "board_id restricts the fetch to that board", %{
      user: user,
      board: board,
      column: column,
      scope: scope
    } do
      other_column = user |> board_fixture() |> column_fixture()
      kept = task_fixture(column)
      _dropped = task_fixture(other_column)

      result = Agents.fetch_tasks(scope: scope, board_id: board.id)
      assert Enum.map(result, & &1.id) == [kept.id]
    end

    test "board_id for a board the user cannot access returns empty", %{scope: scope} do
      foreign_board = user_fixture() |> board_fixture()
      foreign_column = column_fixture(foreign_board)
      _foreign = task_fixture(foreign_column)

      # BoardScope membership — not the board_id filter — is the guard: the
      # foreign board's task is absent from the scope-only fetch too, and the
      # board_id filter then intersects to the same empty set.
      assert Agents.fetch_tasks(scope: scope) == []
      assert Agents.fetch_tasks(scope: scope, board_id: foreign_board.id) == []
    end

    test "time_range :today keeps today's task and drops an earlier one",
         %{column: column, scope: scope} do
      today_task = task_fixture(column)
      earlier = task_fixture(column)
      backdate_updated_at(earlier, ~N[2020-01-01 00:00:00])

      ids = scope |> then(&Agents.fetch_tasks(scope: &1, time_range: :today)) |> Enum.map(& &1.id)
      assert today_task.id in ids
      refute earlier.id in ids
    end

    test "board_id and time_range compose to in-board, in-window tasks only", %{
      user: user,
      board: board,
      column: column,
      scope: scope
    } do
      out_of_board = user |> board_fixture() |> column_fixture()
      kept = task_fixture(column)
      in_board_old = task_fixture(column)
      backdate_updated_at(in_board_old, ~N[2020-01-01 00:00:00])
      _out_of_board_recent = task_fixture(out_of_board)

      result = Agents.fetch_tasks(scope: scope, board_id: board.id, time_range: :last_7_days)
      assert Enum.map(result, & &1.id) == [kept.id]
    end

    test "time_range excludes tasks updated before the window", %{column: column, scope: scope} do
      recent = task_fixture(column)
      old = task_fixture(column)
      backdate_updated_at(old, ~N[2020-01-01 00:00:00])

      ids =
        scope
        |> then(&Agents.fetch_tasks(scope: &1, time_range: :last_7_days))
        |> Enum.map(& &1.id)

      assert recent.id in ids
      refute old.id in ids
    end

    test "all_time and nil time_range are a no-op", %{column: column, scope: scope} do
      column |> task_fixture() |> backdate_updated_at(~N[2020-01-01 00:00:00])

      assert length(Agents.fetch_tasks(scope: scope, time_range: :all_time)) == 1
      assert length(Agents.fetch_tasks(scope: scope, time_range: nil)) == 1
    end

    defp backdate_updated_at(%{id: id} = task, %NaiveDateTime{} = at) do
      from(t in Tasks.Task, where: t.id == ^id)
      |> Repo.update_all(set: [updated_at: at])

      task
    end
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

    test "infers :working when the agent has a task in the Doing column", %{board: board} do
      doing = column_fixture(board, %{name: "Doing"})

      {:ok, task} =
        doing
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Claude", status: :in_progress})

      [%Agent{name: "Claude", status: :working, current_task: current}] = Agents.list_agents()

      assert current == %{identifier: task.identifier, title: task.title}
    end

    test "infers :waiting when the agent's only in-progress tasks are in the Review column",
         %{board: board} do
      review = column_fixture(board, %{name: "Review"})

      # A task that needs review is moved to the Review column but deliberately
      # keeps the :in_progress status until approval — the agent is waiting, not
      # working, and there must be no current-task pill.
      {:ok, _} =
        review
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          completed_by_agent: "Claude",
          completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          status: :in_progress,
          needs_review: true
        })

      [%Agent{name: "Claude", status: :waiting, current_task: nil}] = Agents.list_agents()
    end

    test "prefers the Doing-column task as current when work spans Doing and Review",
         %{board: board} do
      doing = column_fixture(board, %{name: "Doing"})
      review = column_fixture(board, %{name: "Review"})

      {:ok, _review_task} =
        review
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Claude", status: :in_progress})

      {:ok, doing_task} =
        doing
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Claude", status: :in_progress})

      [%Agent{name: "Claude", status: :working, current_task: current}] = Agents.list_agents()

      assert current == %{identifier: doing_task.identifier, title: doing_task.title}
    end

    test "infers :idle when the agent's only tasks are in the Done column", %{board: board} do
      done = column_fixture(board, %{name: "Done"})

      {:ok, _} =
        done
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          completed_by_agent: "Claude",
          completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          status: :completed
        })

      [%Agent{name: "Claude", status: :idle, current_task: nil}] = Agents.list_agents()
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

    test "derives the event owner from the same Task->User associations", %{column: column} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      owner_user = user_fixture(%{name: "Jeffrey"})

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          completed_by_agent: "Claude",
          created_by_id: owner_user.id,
          completed_by_id: owner_user.id,
          claimed_at: now,
          completed_at: now
        })

      for event <- Agents.recent_activity() do
        assert event.owner.id == owner_user.id
        assert event.owner.name == "Jeffrey"
      end
    end

    test "event owner is nil when no user association can be derived", %{column: column} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          completed_by_agent: "Claude",
          claimed_at: now,
          completed_at: now
        })

      for event <- Agents.recent_activity() do
        assert event.owner == nil
      end
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

    test "counts a completion under the user's local today even when its UTC instant is the next UTC day",
         %{column: column} do
      tz = "America/New_York"
      {:ok, local_now} = DateTime.now(tz)
      local_today = DateTime.to_date(local_now)
      # 23:30 local today in a west zone lands on the NEXT UTC day — a UTC-date
      # comparison would mislabel it; the local-date comparison must not.
      {:ok, local_dt} = DateTime.new(local_today, ~T[23:30:00], tz)
      utc_completed = local_dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)

      {:ok, task} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{completed_at: utc_completed, time_spent_minutes: 45})

      stats = Agents.header_stats_from([task], tz)
      assert stats.completed_today == 1
      assert stats.avg_cycle_minutes == 45.0
    end

    test "avg_cycle_minutes averages only completions on the local today", %{column: column} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      three_days_ago = DateTime.add(now, -3, :day)

      {:ok, today_task} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{completed_at: now, time_spent_minutes: 45})

      {:ok, old_task} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{completed_at: three_days_ago, time_spent_minutes: 90})

      stats = Agents.header_stats_from([today_task, old_task], "Etc/UTC")
      # Only today's 45-minute completion is averaged; the 3-day-old 90 is excluded.
      assert stats.avg_cycle_minutes == 45.0
      assert stats.completed_today == 1
    end

    test "no completions on the local today yields a 0.0 cycle time with no error",
         %{column: column} do
      two_days_ago = DateTime.add(DateTime.utc_now(), -2, :day) |> DateTime.truncate(:second)

      {:ok, task} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{completed_at: two_days_ago, time_spent_minutes: 60})

      stats = Agents.header_stats_from([task], "Etc/UTC")
      assert stats.avg_cycle_minutes == 0.0
      assert stats.completed_today == 0
    end

    test "an unknown timezone falls back to UTC", %{column: column} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, task} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          claimed_at: now,
          completed_at: now,
          time_spent_minutes: 30
        })

      # A malformed zone must not raise; it behaves exactly like Etc/UTC.
      assert Agents.header_stats_from([task], "Not/AZone") ==
               Agents.header_stats_from([task], "Etc/UTC")
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

  describe "Agent struct" do
    test "defaults owner to nil" do
      assert %Agent{}.owner == nil
    end

    test "carries a derived owner map when set" do
      owner = %{id: 1, name: "Jeffrey"}
      assert %Agent{owner: owner}.owner == owner
    end

    test "defaults stuck to false" do
      assert %Agent{}.stuck == false
    end
  end

  describe "list_agents/1 stuck classification" do
    defp ago(minutes) do
      DateTime.utc_now() |> DateTime.add(-minutes * 60, :second) |> DateTime.truncate(:second)
    end

    test "an agent stalled in Doing past the threshold is stuck", %{board: board} do
      doing = column_fixture(board, %{name: "Doing"})

      {:ok, _} =
        doing
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          status: :in_progress,
          claimed_at: ago(90)
        })

      assert [%Agent{name: "Claude", status: :working, stuck: true}] = Agents.list_agents()
    end

    test "an agent sitting in review past the threshold is stuck", %{board: board} do
      review = column_fixture(board, %{name: "Review"})

      {:ok, _} =
        review
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          completed_by_agent: "Claude",
          status: :in_progress,
          completed_at: ago(90),
          needs_review: true
        })

      assert [%Agent{name: "Claude", status: :waiting, stuck: true}] = Agents.list_agents()
    end

    test "an agent active just below the threshold is not stuck", %{board: board} do
      doing = column_fixture(board, %{name: "Doing"})

      {:ok, _} =
        doing
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          status: :in_progress,
          claimed_at: ago(30)
        })

      assert [%Agent{name: "Claude", status: :working, stuck: false}] = Agents.list_agents()
    end

    test "an active agent with no claimed_at is not stuck (recent inserted_at)", %{board: board} do
      doing = column_fixture(board, %{name: "Doing"})

      {:ok, _} =
        doing
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Claude", status: :in_progress})

      assert [%Agent{name: "Claude", stuck: false}] = Agents.list_agents()
    end

    test "an idle agent is not stuck even with an old completed task", %{board: board} do
      done = column_fixture(board, %{name: "Done"})

      {:ok, _} =
        done
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          completed_by_agent: "Claude",
          status: :completed,
          completed_at: ago(90)
        })

      assert [%Agent{name: "Claude", status: :idle, stuck: false}] = Agents.list_agents()
    end
  end

  describe "list_agents/1 owner derivation" do
    test "derives owner from the created_by user", %{column: column} do
      owner_user = user_fixture(%{name: "Jeffrey"})

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Claude", created_by_id: owner_user.id})

      [%Agent{name: "Claude", owner: owner}] = Agents.list_agents()

      assert owner.id == owner_user.id
      assert owner.name == "Jeffrey"
      assert owner.email == owner_user.email
    end

    test "derives owner from completed_by when created_by has no user", %{column: column} do
      owner_user = user_fixture(%{name: "Casey"})

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          completed_by_agent: "Claude",
          completed_by_id: owner_user.id
        })

      [%Agent{name: "Claude", owner: owner}] = Agents.list_agents()

      assert owner.id == owner_user.id
      assert owner.name == "Casey"
    end

    test "owner is nil when no user association can be derived", %{column: column} do
      {:ok, _} = column |> task_fixture() |> Tasks.update_task(%{created_by_agent: "Claude"})

      [%Agent{name: "Claude", owner: nil}] = Agents.list_agents()
    end
  end

  describe "fleet_health/1" do
    test "returns all zeros for an empty agent set" do
      assert Agents.fleet_health() == %{working: 0, waiting: 0, idle: 0, stuck: 0}
    end

    test "counts agents per status with stuck as a cross-cutting count", %{board: board} do
      doing = column_fixture(board, %{name: "Doing"})
      review = column_fixture(board, %{name: "Review"})
      done = column_fixture(board, %{name: "Done"})

      # working, not stuck
      {:ok, _} =
        doing
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Worker",
          status: :in_progress,
          claimed_at: ago(5)
        })

      # waiting (sitting in review), not stuck
      {:ok, _} =
        review
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Reviewer",
          completed_by_agent: "Reviewer",
          status: :in_progress,
          completed_at: ago(5),
          needs_review: true
        })

      # idle (only a done task)
      {:ok, _} =
        done
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Idler",
          completed_by_agent: "Idler",
          status: :completed,
          completed_at: ago(5)
        })

      # working AND stuck (stalled in Doing past the threshold)
      {:ok, _} =
        doing
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Stalled",
          status: :in_progress,
          claimed_at: ago(90)
        })

      assert Agents.fleet_health() == %{working: 2, waiting: 1, idle: 1, stuck: 1}
    end

    test "all-idle agent set counts only idle", %{column: column} do
      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          completed_by_agent: "Claude",
          status: :completed,
          completed_at: ago(5)
        })

      assert Agents.fleet_health() == %{working: 0, waiting: 0, idle: 1, stuck: 0}
    end

    test "respects :scope board filtering", %{column: column} do
      {:ok, _} = column |> task_fixture() |> Tasks.update_task(%{created_by_agent: "Claude"})

      other_scope = Scope.for_user(user_fixture())

      assert Agents.fleet_health(scope: other_scope) == %{
               working: 0,
               waiting: 0,
               idle: 0,
               stuck: 0
             }
    end
  end

  describe "throughput_and_success/1" do
    test "returns all zeros for empty data" do
      assert Agents.throughput_and_success() == %{
               completed_today: 0,
               completed_7d: 0,
               completed_30d: 0,
               completed_prev_today: 0,
               completed_prev_7d: 0,
               completed_prev_30d: 0,
               success_rate: 0.0
             }
    end

    test "counts throughput over the today, 7-day, and 30-day windows", %{
      column: column,
      user: user
    } do
      complete_at(column, user, days_ago(0), :approved)
      complete_at(column, user, days_ago(3), :approved)
      complete_at(column, user, days_ago(20), :approved)
      complete_at(column, user, days_ago(40), :approved)

      assert Agents.throughput_and_success() == %{
               completed_today: 1,
               completed_7d: 2,
               completed_30d: 3,
               completed_prev_today: 0,
               completed_prev_7d: 0,
               completed_prev_30d: 1,
               success_rate: 1.0
             }
    end

    test "computes the overall success rate from approved and rejected tasks", %{
      column: column,
      user: user
    } do
      complete_at(column, user, days_ago(0), :approved)
      complete_at(column, user, days_ago(0), :approved)
      complete_at(column, user, days_ago(0), :approved)
      complete_at(column, user, days_ago(0), :rejected)

      assert Agents.throughput_and_success() == %{
               completed_today: 4,
               completed_7d: 4,
               completed_30d: 4,
               completed_prev_today: 0,
               completed_prev_7d: 0,
               completed_prev_30d: 0,
               success_rate: 0.75
             }
    end

    test "returns zero throughput and zero success rate when no task is completed", %{
      column: column
    } do
      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Claude", status: :in_progress})

      assert Agents.throughput_and_success() == %{
               completed_today: 0,
               completed_7d: 0,
               completed_30d: 0,
               completed_prev_today: 0,
               completed_prev_7d: 0,
               completed_prev_30d: 0,
               success_rate: 0.0
             }
    end

    test "reports a 0.0 success rate when every reviewed task failed", %{
      column: column,
      user: user
    } do
      complete_at(column, user, days_ago(0), :rejected)
      complete_at(column, user, days_ago(0), :rejected)

      assert Agents.throughput_and_success() == %{
               completed_today: 2,
               completed_7d: 2,
               completed_30d: 2,
               completed_prev_today: 0,
               completed_prev_7d: 0,
               completed_prev_30d: 0,
               success_rate: 0.0
             }
    end

    test "counts a task touched by two agents once, with no double-count", %{
      column: column,
      user: user
    } do
      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Creator",
          completed_by_agent: "Worker",
          status: :completed,
          completed_at: days_ago(0),
          review_status: :approved,
          reviewed_at: days_ago(0),
          reviewed_by_id: user.id
        })

      assert Agents.throughput_and_success() == %{
               completed_today: 1,
               completed_7d: 1,
               completed_30d: 1,
               completed_prev_today: 0,
               completed_prev_7d: 0,
               completed_prev_30d: 0,
               success_rate: 1.0
             }
    end

    test "respects :scope board filtering", %{column: column, user: user} do
      complete_at(column, user, days_ago(0), :approved)

      other_scope = Scope.for_user(user_fixture())

      assert Agents.throughput_and_success(scope: other_scope) == %{
               completed_today: 0,
               completed_7d: 0,
               completed_30d: 0,
               completed_prev_today: 0,
               completed_prev_7d: 0,
               completed_prev_30d: 0,
               success_rate: 0.0
             }
    end

    test "counts prior-period completions for the today/7d/30d windows", %{
      column: column,
      user: user
    } do
      complete_at(column, user, days_ago(0), :approved)
      complete_at(column, user, days_ago(0), :approved)
      # Yesterday -> prior-today window.
      complete_at(column, user, days_ago(1), :approved)
      # 10 days ago -> prior-7d window (the 7 days before the current 7).
      complete_at(column, user, days_ago(10), :approved)
      # 40 days ago -> prior-30d window (the 30 days before the current 30).
      complete_at(column, user, days_ago(40), :approved)

      result = Agents.throughput_and_success()

      assert result.completed_today == 2
      assert result.completed_7d == 3
      assert result.completed_30d == 4
      assert result.completed_prev_today == 1
      assert result.completed_prev_7d == 1
      assert result.completed_prev_30d == 1
    end

    defp complete_at(column, user, completed_at, review_status) do
      {:ok, task} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          completed_by_agent: "Claude",
          status: :completed,
          completed_at: completed_at,
          review_status: review_status,
          reviewed_at: completed_at,
          reviewed_by_id: user.id
        })

      task
    end

    defp days_ago(days) do
      DateTime.utc_now()
      |> DateTime.add(-days * 86_400, :second)
      |> DateTime.truncate(:second)
    end
  end

  describe "throughput_and_success_from/2 local-today parity" do
    test "header and Delivery-trends completed_today are equal for the same task set and timezone",
         %{column: column, user: user} do
      tasks = [
        complete_at(column, user, days_ago(0), :approved),
        complete_at(column, user, days_ago(0), :rejected),
        complete_at(column, user, days_ago(3), :approved)
      ]

      tz = "America/Los_Angeles"

      assert Agents.header_stats_from(tasks, tz).completed_today ==
               Agents.throughput_and_success_from(tasks, tz).completed_today
    end

    test "both count a completion under the user's local today even when its UTC instant is the next UTC day",
         %{column: column} do
      tz = "America/New_York"
      {:ok, local_now} = DateTime.now(tz)
      local_today = DateTime.to_date(local_now)
      # 23:30 local today in a west zone lands on the NEXT UTC day — a UTC-date
      # comparison would mislabel it; both stats must use the local date.
      {:ok, local_dt} = DateTime.new(local_today, ~T[23:30:00], tz)
      utc_completed = local_dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)

      {:ok, task} =
        column |> task_fixture() |> Tasks.update_task(%{completed_at: utc_completed})

      header = Agents.header_stats_from([task], tz)
      trends = Agents.throughput_and_success_from([task], tz)

      assert trends.completed_today == 1
      assert header.completed_today == trends.completed_today
    end

    test "an unknown timezone falls back to UTC and the two stats still agree",
         %{column: column, user: user} do
      tasks = [complete_at(column, user, days_ago(0), :approved)]

      header = Agents.header_stats_from(tasks, "Mars/Phobos")
      trends = Agents.throughput_and_success_from(tasks, "Mars/Phobos")

      assert trends.completed_today == 1
      assert header.completed_today == trends.completed_today
    end

    test "completed_prev_today counts the user's local yesterday, not the UTC yesterday",
         %{column: column} do
      tz = "America/New_York"
      {:ok, local_now} = DateTime.now(tz)
      local_yesterday = local_now |> DateTime.to_date() |> Date.add(-1)
      # 23:30 on local yesterday rolls into the current UTC day; a UTC basis
      # would bucket it as "today", the local basis as "prev today".
      {:ok, local_dt} = DateTime.new(local_yesterday, ~T[23:30:00], tz)
      utc_completed = local_dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)

      {:ok, task} =
        column |> task_fixture() |> Tasks.update_task(%{completed_at: utc_completed})

      trends = Agents.throughput_and_success_from([task], tz)

      assert trends.completed_prev_today == 1
      assert trends.completed_today == 0
    end

    test "completed_7d counts a completion on the user's local today even when its UTC instant is the next UTC day",
         %{column: column} do
      tz = "America/New_York"
      {:ok, local_now} = DateTime.now(tz)
      local_today = DateTime.to_date(local_now)
      {:ok, local_dt} = DateTime.new(local_today, ~T[23:30:00], tz)
      utc_completed = local_dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)

      {:ok, task} =
        column |> task_fixture() |> Tasks.update_task(%{completed_at: utc_completed})

      assert Agents.throughput_and_success_from([task], tz).completed_7d == 1
    end
  end

  describe "list_agents_from/2 roster timezone" do
    test "per-agent today counts a completion under the user's local day, not the UTC day",
         %{column: column} do
      tz = "America/New_York"
      {:ok, local_now} = DateTime.now(tz)
      local_today = DateTime.to_date(local_now)
      # 23:30 local today in a west zone lands on the NEXT UTC day; a UTC-date
      # roster count would mislabel it, the local-date count must not.
      {:ok, local_dt} = DateTime.new(local_today, ~T[23:30:00], tz)
      utc_completed = local_dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)

      {:ok, _task} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          completed_by_agent: "Claude",
          status: :completed,
          completed_at: utc_completed
        })

      tasks = Agents.fetch_tasks([])
      [agent] = Agents.list_agents_from(tasks, tz)

      assert agent.today == 1
    end

    test "per-agent last_7d counts a completion three days ago", %{column: column, user: user} do
      _task = complete_at(column, user, days_ago(3), :approved)

      tasks = Agents.fetch_tasks([])
      [agent] = Agents.list_agents_from(tasks, "America/Los_Angeles")

      assert agent.last_7d == 1
    end

    test "an unknown timezone falls back to UTC", %{column: column, user: user} do
      _task = complete_at(column, user, days_ago(0), :approved)

      tasks = Agents.fetch_tasks([])
      [agent] = Agents.list_agents_from(tasks, "Mars/Phobos")

      assert agent.today == 1
    end
  end

  describe "local_today/1 and local_date/2" do
    test "local_today returns a Date and falls back to the UTC date for an unknown zone" do
      assert %Date{} = Agents.local_today("America/New_York")
      assert Agents.local_today("Mars/Phobos") == Date.utc_today()
    end

    test "local_date shifts a UTC timestamp into the viewer's calendar day" do
      # 02:00 UTC on Jan 1 is still Dec 31 in New York (UTC-5).
      dt = ~U[2026-01-01 02:00:00Z]

      assert Agents.local_date(dt, "America/New_York") == ~D[2025-12-31]
      assert Agents.local_date(dt, "Etc/UTC") == ~D[2026-01-01]
    end

    test "local_date falls back to the UTC date for an unknown zone" do
      dt = ~U[2026-01-01 02:00:00Z]
      assert Agents.local_date(dt, "Mars/Phobos") == ~D[2026-01-01]
    end
  end

  describe "throughput_trends/1" do
    test "buckets throughput per day across the window, oldest first", %{
      column: column,
      user: user
    } do
      complete_with_cycle(column, user, days_ago(0), 10)
      complete_with_cycle(column, user, days_ago(0), 20)
      complete_with_cycle(column, user, days_ago(1), 30)

      today = Date.utc_today()

      assert Agents.throughput_trends(days: 3).series == [
               %{date: Date.add(today, -2), count: 0},
               %{date: Date.add(today, -1), count: 1},
               %{date: today, count: 2}
             ]
    end

    test "averages time_spent_minutes as the aggregate cycle-time metric", %{
      column: column,
      user: user
    } do
      complete_with_cycle(column, user, days_ago(0), 10)
      complete_with_cycle(column, user, days_ago(0), 20)
      complete_with_cycle(column, user, days_ago(1), 60)
      # A completed task with no recorded time is excluded from the average.
      complete_at(column, user, days_ago(0), :approved)

      assert Agents.throughput_trends().avg_cycle_minutes == 30.0
    end

    test "returns a zero-filled series and zero cycle time for an empty window" do
      today = Date.utc_today()

      assert Agents.throughput_trends(days: 3) == %{
               series: [
                 %{date: Date.add(today, -2), count: 0},
                 %{date: Date.add(today, -1), count: 0},
                 %{date: today, count: 0}
               ],
               avg_cycle_minutes: 0.0
             }
    end

    test "returns a single bucket for a one-day window", %{column: column, user: user} do
      complete_with_cycle(column, user, days_ago(0), 15)

      assert Agents.throughput_trends(days: 1).series == [
               %{date: Date.utc_today(), count: 1}
             ]
    end

    test "returns an empty series for a non-positive window" do
      assert Agents.throughput_trends(days: 0).series == []
    end

    test "respects :scope board filtering", %{column: column, user: user} do
      complete_with_cycle(column, user, days_ago(0), 10)

      other_scope = Scope.for_user(user_fixture())
      today = Date.utc_today()

      assert Agents.throughput_trends(days: 2, scope: other_scope) == %{
               series: [
                 %{date: Date.add(today, -1), count: 0},
                 %{date: today, count: 0}
               ],
               avg_cycle_minutes: 0.0
             }
    end

    defp complete_with_cycle(column, user, completed_at, minutes) do
      {:ok, task} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          completed_by_agent: "Claude",
          status: :completed,
          completed_at: completed_at,
          time_spent_minutes: minutes,
          review_status: :approved,
          reviewed_at: completed_at,
          reviewed_by_id: user.id
        })

      task
    end
  end

  describe "throughput_trends_from/3 local-day bucketing" do
    test "buckets a completion on the viewer's local day even when its UTC instant is the next UTC day",
         %{column: column} do
      tz = "America/New_York"
      {:ok, local_now} = DateTime.now(tz)
      local_today = DateTime.to_date(local_now)
      # 23:30 local today in a west zone lands on the NEXT UTC day — UTC bucketing
      # would file it under the wrong day; local bucketing must use local_today.
      {:ok, local_dt} = DateTime.new(local_today, ~T[23:30:00], tz)
      utc_completed = local_dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)

      {:ok, task} =
        column |> task_fixture() |> Tasks.update_task(%{completed_at: utc_completed})

      series = Agents.throughput_trends_from([task], 2, tz).series

      assert series == [
               %{date: Date.add(local_today, -1), count: 0},
               %{date: local_today, count: 1}
             ]
    end

    test "the most-recent bucket equals the local Completed-today value for the same task set and tz",
         %{column: column, user: user} do
      tasks = [
        complete_at(column, user, days_ago(0), :approved),
        complete_at(column, user, days_ago(0), :rejected),
        complete_at(column, user, days_ago(5), :approved)
      ]

      tz = "America/Los_Angeles"

      last_bucket = List.last(Agents.throughput_trends_from(tasks, 7, tz).series)

      assert last_bucket.count == Agents.throughput_and_success_from(tasks, tz).completed_today
    end

    test "an unknown timezone falls back to UTC bucketing without raising",
         %{column: column, user: user} do
      task = complete_at(column, user, days_ago(0), :approved)

      series = Agents.throughput_trends_from([task], 2, "Mars/Phobos").series

      assert series == [
               %{date: Date.add(Date.utc_today(), -1), count: 0},
               %{date: Date.utc_today(), count: 1}
             ]
    end

    test "returns a zero-filled series anchored on the viewer's local today for an empty window" do
      tz = "America/New_York"
      {:ok, local_now} = DateTime.now(tz)
      local_today = DateTime.to_date(local_now)

      assert Agents.throughput_trends_from([], 3, tz).series == [
               %{date: Date.add(local_today, -2), count: 0},
               %{date: Date.add(local_today, -1), count: 0},
               %{date: local_today, count: 0}
             ]
    end

    test "default_trend_days/0 is the default window and yields that many buckets" do
      assert Agents.default_trend_days() == 14
      assert length(Agents.throughput_trends_from([], Agents.default_trend_days()).series) == 14
    end
  end

  describe "dormant classification" do
    test "flags an agent dormant when its last activity is older than 14 days",
         %{column: column} do
      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Stale", claimed_at: days_ago(20)})

      agent = Enum.find(Agents.list_agents(), &(&1.name == "Stale"))
      expected_date = days_ago(20) |> DateTime.to_date()

      assert agent.dormant == true
      assert %NaiveDateTime{} = agent.last_active_at
      assert NaiveDateTime.to_date(agent.last_active_at) == expected_date
    end

    test "does not flag an agent active within the last 14 days as dormant",
         %{column: column} do
      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Fresh", claimed_at: days_ago(13)})

      agent = Enum.find(Agents.list_agents(), &(&1.name == "Fresh"))

      assert agent.dormant == false
    end

    test "flags an agent just past the 14-day threshold as dormant", %{column: column} do
      # 14 days and one hour ago — unambiguously older than the 14-day cutoff,
      # bracketing the threshold against the 13-day not-dormant case above.
      just_past =
        DateTime.utc_now()
        |> DateTime.add(-(14 * 24 * 60 * 60 + 3600), :second)
        |> DateTime.truncate(:second)

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Edge", claimed_at: just_past})

      agent = Enum.find(Agents.list_agents(), &(&1.name == "Edge"))

      assert agent.dormant == true
    end

    test "last_active_at reflects the most recent activity across the agent's tasks",
         %{column: column} do
      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Multi", claimed_at: days_ago(30)})

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Multi",
          completed_by_agent: "Multi",
          status: :completed,
          completed_at: days_ago(2)
        })

      agent = Enum.find(Agents.list_agents(), &(&1.name == "Multi"))
      expected_date = days_ago(2) |> DateTime.to_date()

      assert NaiveDateTime.to_date(agent.last_active_at) == expected_date
      assert agent.dormant == false
    end

    test "fleet_health excludes dormant agents from all counts but list_agents keeps them",
         %{board: board, column: column} do
      doing = column_fixture(board, %{name: "Doing"})

      # Live working agent (active 5 minutes ago).
      {:ok, _} =
        doing
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Live",
          status: :in_progress,
          claimed_at: ago(5)
        })

      # Dormant idle agent (last completed 20 days ago).
      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Ghost",
          completed_by_agent: "Ghost",
          status: :completed,
          completed_at: days_ago(20)
        })

      assert Agents.fleet_health() == %{working: 1, waiting: 0, idle: 0, stuck: 0}
      assert Enum.any?(Agents.list_agents(), &(&1.name == "Ghost" and &1.dormant))
    end

    test "fleet_health returns all zeros when every agent is dormant", %{column: column} do
      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Ghost",
          completed_by_agent: "Ghost",
          status: :completed,
          completed_at: days_ago(30)
        })

      assert Agents.fleet_health() == %{working: 0, waiting: 0, idle: 0, stuck: 0}
    end
  end

  describe "agent_detail/2" do
    test "returns the drill-down for a populated agent", %{board: board, user: user} do
      doing = column_fixture(board, %{name: "Doing"})
      done = column_fixture(board, %{name: "Done"})
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, doing_task} =
        doing
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          completed_by_agent: "Claude",
          status: :in_progress,
          claimed_at: now
        })

      {:ok, _rejected} =
        done
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          completed_by_agent: "Claude",
          status: :completed,
          claimed_at: now,
          completed_at: now,
          review_status: :rejected,
          reviewed_at: now,
          reviewed_by_id: user.id
        })

      detail = Agents.agent_detail("Claude")

      assert detail.name == "Claude"
      assert detail.current_task == %{identifier: doing_task.identifier, title: doing_task.title}
      # Both tasks were claimed by Claude.
      assert length(detail.claims) == 2
      assert [%{identifier: _, title: _, at: %DateTime{}} | _] = detail.claims
      assert length(detail.failures) == 1
      assert detail.recent_activity != []
    end

    test "returns a 14-day daily completion series for the agent", %{column: column} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          completed_by_agent: "Claude",
          status: :completed,
          completed_at: now
        })

      detail = Agents.agent_detail("Claude")

      assert length(detail.activity_series) == 14

      assert Enum.all?(
               detail.activity_series,
               &match?(%{date: %Date{}, count: c} when is_integer(c) and c >= 0, &1)
             )

      # The series is oldest-first, so the most recent bucket (today) carries
      # the single completion seeded above.
      assert List.last(detail.activity_series).count == 1
    end

    test "returns an approved/rejected/in_progress outcome breakdown",
         %{board: board, user: user} do
      doing = column_fixture(board, %{name: "Doing"})
      done = column_fixture(board, %{name: "Done"})
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      for _ <- 1..2 do
        {:ok, _} =
          done
          |> task_fixture()
          |> Tasks.update_task(%{
            created_by_agent: "Claude",
            completed_by_agent: "Claude",
            status: :completed,
            completed_at: now,
            review_status: :approved,
            reviewed_at: now,
            reviewed_by_id: user.id
          })
      end

      {:ok, _} =
        done
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          completed_by_agent: "Claude",
          status: :completed,
          completed_at: now,
          review_status: :rejected,
          reviewed_at: now,
          reviewed_by_id: user.id
        })

      {:ok, _} =
        doing
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          completed_by_agent: "Claude",
          status: :in_progress,
          claimed_at: now
        })

      detail = Agents.agent_detail("Claude")

      assert detail.outcome.approved == 2
      assert detail.outcome.rejected == 1
      assert detail.outcome.in_progress == 1
      assert_in_delta detail.outcome.success_rate, 2 / 3, 0.001
    end

    test "outcome.success_rate is 0.0 with no reviewed tasks (no divide-by-zero)",
         %{column: column} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          completed_by_agent: "Claude",
          status: :in_progress,
          claimed_at: now
        })

      detail = Agents.agent_detail("Claude")

      assert detail.outcome.success_rate == 0.0
      assert detail.outcome.approved == 0
      assert detail.outcome.rejected == 0
    end

    test "returns nil for an unknown agent" do
      assert Agents.agent_detail("Nobody") == nil
    end

    test "surfaces rejected tasks as failures", %{column: column, user: user} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, task} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          completed_by_agent: "Claude",
          status: :completed,
          completed_at: now,
          review_status: :rejected,
          reviewed_at: now,
          reviewed_by_id: user.id
        })

      detail = Agents.agent_detail("Claude")

      assert [%{identifier: id, title: _, at: %DateTime{}}] = detail.failures
      assert id == task.identifier
    end

    test "returns a nil current_task when the agent holds no Doing task", %{column: column} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          completed_by_agent: "Claude",
          status: :completed,
          claimed_at: now,
          completed_at: now
        })

      detail = Agents.agent_detail("Claude")

      assert detail.current_task == nil
      # Claim history is still surfaced even with no active task.
      assert length(detail.claims) == 1
      assert detail.failures == []
    end

    test "handles an agent whose only work was rejected", %{column: column, user: user} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          completed_by_agent: "Claude",
          status: :completed,
          completed_at: now,
          review_status: :rejected,
          reviewed_at: now,
          reviewed_by_id: user.id
        })

      detail = Agents.agent_detail("Claude")

      assert detail.current_task == nil
      assert length(detail.failures) == 1
    end

    test "respects :scope and returns nil for another user's scope", %{column: column} do
      {:ok, _} = column |> task_fixture() |> Tasks.update_task(%{created_by_agent: "Claude"})

      other_scope = Scope.for_user(user_fixture())

      assert Agents.agent_detail("Claude", scope: other_scope) == nil
    end
  end

  describe "shared-fetch parity (W1242)" do
    setup %{column: column} do
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

      :ok
    end

    test "every _from variant matches its keyword counterpart for the same scope", %{user: user} do
      scope = Scope.for_user(user)
      tasks = Agents.fetch_tasks(scope: scope)

      assert Agents.list_agents_from(tasks) == Agents.list_agents(scope: scope)
      assert Agents.header_stats_from(tasks) == Agents.header_stats(scope: scope)

      assert Agents.throughput_and_success_from(tasks) ==
               Agents.throughput_and_success(scope: scope)

      assert Agents.throughput_trends_from(tasks) == Agents.throughput_trends(scope: scope)

      assert Agents.throughput_trends_from(tasks, 3) ==
               Agents.throughput_trends(days: 3, scope: scope)

      agents = Agents.list_agents_from(tasks)
      assert Agents.fleet_health_from(agents) == Agents.fleet_health(scope: scope)

      assert Agents.recent_activity_from(tasks, 200) ==
               Agents.recent_activity(scope: scope, limit: 200)

      assert Agents.agent_detail_from(tasks, "Claude") ==
               Agents.agent_detail("Claude", scope: scope)
    end

    test "agent_detail_from returns nil for an unknown agent", %{user: user} do
      scope = Scope.for_user(user)
      tasks = Agents.fetch_tasks(scope: scope)
      assert Agents.agent_detail_from(tasks, "Nobody") == nil
    end

    test "the _from variants operate only on the scoped task list they are given" do
      # A different user's scope yields an empty task list, so every derived
      # value is empty — proving the shared fetch carries the board scoping.
      other = Scope.for_user(user_fixture())
      tasks = Agents.fetch_tasks(scope: other)

      assert tasks == []
      assert Agents.list_agents_from(tasks) == []
      assert Agents.recent_activity_from(tasks, 200) == []
      assert Agents.agent_detail_from(tasks, "Claude") == nil
    end
  end

  describe "agent identity by owner (W1244)" do
    test "two same-named agents under different humans are two distinct agents",
         %{column: column, user: user_a} do
      user_b = user_fixture()

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Claude", created_by_id: user_a.id})

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Claude", created_by_id: user_b.id})

      claudes = Agents.list_agents() |> Enum.filter(&(&1.name == "Claude"))
      assert length(claudes) == 2

      owner_keys = claudes |> Enum.map(& &1.owner_key) |> Enum.sort()
      assert owner_keys == Enum.sort([Integer.to_string(user_a.id), Integer.to_string(user_b.id)])

      owner_ids = claudes |> Enum.map(& &1.owner.id) |> Enum.sort()
      assert owner_ids == Enum.sort([user_a.id, user_b.id])
    end

    test "each same-named agent's stats reflect only its own human's tasks",
         %{column: column, user: user_a} do
      user_b = user_fixture()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # user_a's Claude completes two tasks; user_b's Claude completes one.
      for _ <- 1..2 do
        {:ok, _} =
          column
          |> task_fixture()
          |> Tasks.update_task(%{
            created_by_agent: "Claude",
            created_by_id: user_a.id,
            completed_by_agent: "Claude",
            completed_by_id: user_a.id,
            completed_at: now,
            status: :completed
          })
      end

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          created_by_id: user_b.id,
          completed_by_agent: "Claude",
          completed_by_id: user_b.id,
          completed_at: now,
          status: :completed
        })

      agents = Agents.list_agents()
      claude_a = Enum.find(agents, &(&1.owner_key == Integer.to_string(user_a.id)))
      claude_b = Enum.find(agents, &(&1.owner_key == Integer.to_string(user_b.id)))

      assert claude_a.today == 2
      assert claude_b.today == 1
    end

    test "same-named agents with no resolvable owner collapse to one 'none' identity",
         %{column: column} do
      {:ok, _} = column |> task_fixture() |> Tasks.update_task(%{created_by_agent: "Ghost"})
      {:ok, _} = column |> task_fixture() |> Tasks.update_task(%{created_by_agent: "Ghost"})

      assert [%Agent{owner_key: "none", owner: nil}] =
               Enum.filter(Agents.list_agents(), &(&1.name == "Ghost"))
    end

    test "agent_detail_from keyed by identity drills into only that human's tasks",
         %{column: column, user: user_a} do
      user_b = user_fixture()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          created_by_id: user_a.id,
          claimed_at: now
        })

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          created_by_id: user_b.id,
          claimed_at: now
        })

      tasks = Agents.fetch_tasks([])
      detail_a = Agents.agent_detail_from(tasks, {"Claude", Integer.to_string(user_a.id)})

      # Only user_a's single claim is in the drill-down, not both humans' tasks.
      assert detail_a.name == "Claude"
      assert length(detail_a.claims) == 1
    end
  end
end
