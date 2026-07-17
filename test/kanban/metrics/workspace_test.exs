defmodule Kanban.Metrics.WorkspaceTest do
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Metrics.Workspace
  alias Kanban.Tasks

  defp ws_setup do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board)
    %{user: user, board: board, column: column, scope: Scope.for_user(user)}
  end

  defp ws_complete!(task, days_ago, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    completed_at = DateTime.add(now, -days_ago * 86_400, :second)
    claimed_at = DateTime.add(completed_at, -3600, :second)

    final =
      Map.merge(
        %{claimed_at: claimed_at, completed_at: completed_at},
        Map.new(attrs)
      )

    {:ok, t} = Tasks.update_task(task, final)
    t
  end

  describe "workspace reads — local timezone bucketing (W1267)" do
    # Anchor test data to a fixed day in the middle of the window (computed from
    # the viewer's local "today"), so the assertions are robust to the wall-clock
    # time the suite runs at. America/Edmonton is MDT (UTC-6) in June.
    test "throughput_daily splits a UTC day into two local days for a western zone" do
      %{column: column, scope: scope} = ws_setup()
      tz = "America/Edmonton"
      d = tz |> Kanban.Timezone.local_today() |> Date.add(-7)
      midnight = Kanban.Timezone.start_of_local_day(d, tz)
      before_mid = DateTime.add(midnight, -3600, :second)
      after_mid = DateTime.add(midnight, 3600, :second)

      column |> task_fixture() |> Tasks.update_task(%{completed_at: before_mid})
      column |> task_fixture() |> Tasks.update_task(%{completed_at: after_mid})

      local = Workspace.throughput_daily(scope: scope, timezone: tz)
      utc = Workspace.throughput_daily(scope: scope)

      # Edmonton: the two completions straddle local midnight -> two separate days.
      assert Enum.filter(local, &(&1 > 0)) == [1, 1]
      assert Enum.sum(local) == 2

      # UTC: both fall on the same UTC calendar day -> one bucket of 2.
      assert Enum.filter(utc, &(&1 > 0)) == [2]
      assert Enum.sum(utc) == 2
    end

    test "cumulative_flow classifies a task by the viewer's local end-of-day" do
      %{column: column, scope: scope} = ws_setup()
      tz = "America/Edmonton"
      d = tz |> Kanban.Timezone.local_today() |> Date.add(-5)
      next_day = Date.add(d, 1)
      # Just after UTC midnight of d+1, but still inside local day d in Edmonton.
      utc_next_midnight = Kanban.Timezone.start_of_local_day(next_day, "Etc/UTC")
      completed = DateTime.add(utc_next_midnight, 60, :second)
      claimed = DateTime.add(completed, -7200, :second)

      column
      |> task_fixture()
      |> Tasks.update_task(%{claimed_at: claimed, completed_at: completed, needs_review: false})

      local_cfd = Workspace.cumulative_flow(scope: scope, timezone: tz)
      utc_cfd = Workspace.cumulative_flow(scope: scope)
      local_snap = Enum.find(local_cfd, &(&1.date == d))
      utc_snap = Enum.find(utc_cfd, &(&1.date == d))

      # Done by Edmonton's end-of-day d, but still "doing" by UTC's end-of-day d.
      assert local_snap.done == 1
      assert utc_snap.done == 0
      assert utc_snap.doing == 1
    end
  end

  describe "workspace reads accept a :timezone option (W1264 pass-through)" do
    # The option is threaded now but not yet consumed; omitting it must match
    # passing the documented "Etc/UTC" default. This invariant holds before and
    # after the later local-day bucketing work (omitted always defaults to UTC).
    setup do
      %{column: column, scope: scope} = ws_setup()
      Enum.each(1..3, fn _ -> column |> task_fixture() |> ws_complete!(1) end)
      %{scope: scope}
    end

    test "workspace_kpis: omitting :timezone equals passing Etc/UTC", %{scope: scope} do
      assert Workspace.workspace_kpis(scope: scope, timezone: "Etc/UTC") ==
               Workspace.workspace_kpis(scope: scope)
    end

    test "cycle_time_daily: omitting :timezone equals passing Etc/UTC", %{scope: scope} do
      assert Workspace.cycle_time_daily(scope: scope, timezone: "Etc/UTC") ==
               Workspace.cycle_time_daily(scope: scope)
    end

    test "throughput_daily: omitting :timezone equals passing Etc/UTC", %{scope: scope} do
      assert Workspace.throughput_daily(scope: scope, timezone: "Etc/UTC") ==
               Workspace.throughput_daily(scope: scope)
    end

    test "agent_leaderboard: omitting :timezone equals passing Etc/UTC", %{scope: scope} do
      assert Workspace.agent_leaderboard(scope: scope, timezone: "Etc/UTC") ==
               Workspace.agent_leaderboard(scope: scope)
    end

    test "cumulative_flow: omitting :timezone equals passing Etc/UTC", %{scope: scope} do
      assert Workspace.cumulative_flow(scope: scope, timezone: "Etc/UTC") ==
               Workspace.cumulative_flow(scope: scope)
    end
  end

  describe "workspace_kpis/1 — zero / nil scope" do
    test "returns the zero map for a user with no boards" do
      user = user_fixture()
      scope = Scope.for_user(user)
      stats = Workspace.workspace_kpis(scope: scope)

      assert stats.cycle_time_median_minutes == 0
      assert stats.lead_time_p75_minutes == 0
      assert stats.throughput_per_day == 0.0
      assert stats.review_wait_minutes == 0
      assert stats.cycle_time_delta_pct == 0.0
      assert stats.lead_time_delta_pct == 0.0
      assert stats.throughput_delta_pct == 0.0
      assert stats.review_wait_delta_pct == 0.0
    end

    test "returns the zero map when :scope is nil" do
      stats = Workspace.workspace_kpis(scope: nil)
      assert stats.cycle_time_median_minutes == 0
      assert stats.throughput_per_day == 0.0
    end

    test "returns the zero map when :scope is a Scope with a nil user" do
      assert Workspace.workspace_kpis(scope: %Scope{user: nil}).cycle_time_median_minutes == 0
    end
  end

  describe "workspace_kpis/1 — aggregation + deltas" do
    test "aggregates cycle time across two boards", %{} do
      user = user_fixture()
      board1 = board_fixture(user)
      board2 = board_fixture(user)
      col1 = column_fixture(board1)
      col2 = column_fixture(board2)

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      completed_at = DateTime.add(now, -1 * 86_400, :second)

      Enum.each(1..3, fn _ ->
        t = task_fixture(col1)
        claimed = DateTime.add(completed_at, -60 * 60, :second)
        Tasks.update_task(t, %{claimed_at: claimed, completed_at: completed_at})
      end)

      Enum.each(1..2, fn _ ->
        t = task_fixture(col2)
        # 180-minute cycle on the second board.
        claimed = DateTime.add(completed_at, -180 * 60, :second)
        Tasks.update_task(t, %{claimed_at: claimed, completed_at: completed_at})
      end)

      stats = Workspace.workspace_kpis(scope: Scope.for_user(user))
      # 5 tasks total: median of [60, 60, 60, 180, 180] = 60
      assert stats.cycle_time_median_minutes == 60
    end

    test "delta_pct is computed against the previous 14-day window",
         %{} do
      %{column: column, scope: scope} = ws_setup()

      # Current window: 3 tasks completed in the last 14 days
      Enum.each(1..3, fn _ -> column |> task_fixture() |> ws_complete!(1) end)

      # Previous window: 1 task completed in the prior 14-day window
      column |> task_fixture() |> ws_complete!(20)

      stats = Workspace.workspace_kpis(scope: scope)

      # Throughput delta: current = 3/14, previous = 1/14, delta = +200%
      assert_in_delta stats.throughput_delta_pct, 200.0, 0.1
    end

    test "delta_pct is 0.0 when the previous window was empty (divide-by-zero guard)",
         %{} do
      %{column: column, scope: scope} = ws_setup()

      Enum.each(1..3, fn _ -> column |> task_fixture() |> ws_complete!(1) end)

      stats = Workspace.workspace_kpis(scope: scope)
      assert stats.cycle_time_delta_pct == 0.0
      assert stats.throughput_delta_pct == 0.0
    end

    test "filters strictly to boards the scoped user belongs to",
         %{} do
      %{column: column, scope: scope} = ws_setup()
      column |> task_fixture() |> ws_complete!(1)

      # A second user with their own board — must not leak into the
      # original user's stats.
      other = user_fixture()
      other_board = board_fixture(other)
      other_col = column_fixture(other_board)
      Enum.each(1..10, fn _ -> other_col |> task_fixture() |> ws_complete!(1) end)

      stats = Workspace.workspace_kpis(scope: scope)
      assert stats.throughput_per_day == 1 / 14
    end
  end

  describe "workspace reads — :board_ids filter (scoped_board_ids/1)" do
    # scoped_board_ids/1 is private; its behavior is exercised through a
    # workspace read. throughput_per_day == completed_count / 14, so the task
    # counts below map directly to the asserted throughput.
    setup do
      user = user_fixture()
      board1 = board_fixture(user)
      board2 = board_fixture(user)
      col1 = column_fixture(board1)
      col2 = column_fixture(board2)

      # 3 tasks on board1, 5 on board2 — distinct counts so leakage is visible.
      Enum.each(1..3, fn _ -> col1 |> task_fixture() |> ws_complete!(1) end)
      Enum.each(1..5, fn _ -> col2 |> task_fixture() |> ws_complete!(1) end)

      %{user: user, board1: board1, board2: board2, scope: Scope.for_user(user)}
    end

    test "no :board_ids option returns all visible board ids (unchanged)", %{scope: scope} do
      stats = Workspace.workspace_kpis(scope: scope)
      assert stats.throughput_per_day == 8 / 14
    end

    test "a subset :board_ids returns exactly that subset", %{scope: scope, board1: board1} do
      stats = Workspace.workspace_kpis(scope: scope, board_ids: [board1.id])
      assert stats.throughput_per_day == 3 / 14
    end

    test "ids the user cannot see are dropped (intersection with visible only)", %{scope: scope} do
      other = user_fixture()
      other_board = board_fixture(other)
      other_col = column_fixture(other_board)
      Enum.each(1..10, fn _ -> other_col |> task_fixture() |> ws_complete!(1) end)

      stats = Workspace.workspace_kpis(scope: scope, board_ids: [other_board.id])
      assert stats.throughput_per_day == 0.0
    end

    test "a visible/invisible mix keeps only the visible ids", %{scope: scope, board1: board1} do
      other = user_fixture()
      other_board = board_fixture(other)

      stats = Workspace.workspace_kpis(scope: scope, board_ids: [board1.id, other_board.id])
      assert stats.throughput_per_day == 3 / 14
    end

    test "an empty :board_ids list intersects to nothing and returns the zero value",
         %{scope: scope} do
      stats = Workspace.workspace_kpis(scope: scope, board_ids: [])
      assert stats.throughput_per_day == 0.0
    end

    test "duplicate ids in :board_ids are not double-counted", %{scope: scope, board1: board1} do
      stats = Workspace.workspace_kpis(scope: scope, board_ids: [board1.id, board1.id])
      assert stats.throughput_per_day == 3 / 14
    end

    test "a different workspace read (throughput_daily/1) also honors :board_ids",
         %{scope: scope, board1: board1} do
      all = Workspace.throughput_daily(scope: scope)
      filtered = Workspace.throughput_daily(scope: scope, board_ids: [board1.id])

      assert Enum.sum(all) == 8
      assert Enum.sum(filtered) == 3
    end
  end

  describe "cycle_time_daily/1" do
    test "returns 14 entries ordered oldest-to-newest with date keys",
         %{} do
      %{scope: scope} = ws_setup()
      entries = Workspace.cycle_time_daily(scope: scope)

      assert length(entries) == 14
      dates = Enum.map(entries, & &1.date)
      assert dates == Enum.sort(dates, Date)

      for %{date: d, minutes: m} <- entries do
        assert %Date{} = d
        assert is_integer(m)
      end
    end

    test "the daily median spans all completed tasks regardless of created_by_agent",
         %{} do
      %{column: column, scope: scope} = ws_setup()

      # 2-hour cycle for an agent-created task today
      agent_task = task_fixture(column, %{created_by_agent: "Claude"})

      ws_complete!(agent_task, 0,
        claimed_at: DateTime.add(DateTime.utc_now(), -2 * 3600, :second)
      )

      # 1-hour cycle for a human-created task today
      human_task = task_fixture(column, %{created_by_agent: nil})

      ws_complete!(human_task, 0, claimed_at: DateTime.add(DateTime.utc_now(), -3600, :second))

      entries = Workspace.cycle_time_daily(scope: scope)
      today = List.last(entries)

      # A single series: median of [60, 120] minutes is 90, with no
      # agent/human split keys present.
      assert today.minutes == 90
      refute Map.has_key?(today, :agent_minutes)
      refute Map.has_key?(today, :human_minutes)
    end

    test "returns 14 zero entries for an empty workspace" do
      scope = Scope.for_user(user_fixture())
      entries = Workspace.cycle_time_daily(scope: scope)
      assert length(entries) == 14
      assert Enum.all?(entries, &(&1.minutes == 0))
    end
  end

  describe "throughput_daily/1" do
    test "returns 14 integer counts ordered oldest-to-newest", %{} do
      %{column: column, scope: scope} = ws_setup()

      # 2 today, 1 three days ago
      Enum.each(1..2, fn _ -> column |> task_fixture() |> ws_complete!(0) end)
      column |> task_fixture() |> ws_complete!(3)

      counts = Workspace.throughput_daily(scope: scope)
      assert length(counts) == 14
      assert List.last(counts) == 2
      assert Enum.at(counts, length(counts) - 1 - 3) == 1
    end

    test "returns 14 zeros for an empty workspace" do
      counts = Workspace.throughput_daily(scope: Scope.for_user(user_fixture()))
      assert counts == List.duplicate(0, 14)
    end

    # Regression for D87: a completed goal (its `completed_at` is set when its
    # last child finishes) must NOT be counted as throughput. Every board-level
    # metric query excludes `type: :goal`; the workspace path must match, or the
    # "today" bar over-counts by the number of goals completed that day (the
    # production 17-vs-14 report).
    test "excludes completed goals so only work/defect tasks are counted" do
      %{column: column, scope: scope} = ws_setup()

      # 2 work tasks completed today — the only throughput that should count.
      Enum.each(1..2, fn _ -> column |> task_fixture() |> ws_complete!(0) end)
      # A goal completed today must be ignored by throughput.
      column |> task_fixture(%{type: :goal}) |> ws_complete!(0)

      counts = Workspace.throughput_daily(scope: scope)
      assert List.last(counts) == 2
    end
  end

  describe "agent_leaderboard/1" do
    test "places agents before humans regardless of completed counts",
         %{} do
      %{column: column, scope: scope, user: user} = ws_setup()

      # 1 agent completion vs 5 human completions — agent must still
      # appear first because :agent contributors precede :human.
      agent_t = task_fixture(column, %{completed_by_agent: "Claude"})
      ws_complete!(agent_t, 1)

      Enum.each(1..5, fn _ ->
        t = task_fixture(column)
        ws_complete!(t, 1, %{completed_by_id: user.id})
      end)

      leaderboard = Workspace.agent_leaderboard(scope: scope)
      assert hd(leaderboard).kind == :agent
      assert hd(leaderboard).name == "Claude"
    end

    test "caps the leaderboard at 6 entries", %{} do
      %{column: column, scope: scope} = ws_setup()

      for i <- 1..10 do
        t = task_fixture(column, %{completed_by_agent: "Agent#{i}"})
        ws_complete!(t, 1)
      end

      leaderboard = Workspace.agent_leaderboard(scope: scope)
      assert length(leaderboard) == 6
    end

    test "computes success_pct from review_status / needs_review",
         %{} do
      %{column: column, scope: scope, user: user} = ws_setup()

      # 2 tasks for Claude: one approved (needs_review=true + :approved),
      # one no-review (needs_review=false) — both successful → 100%.
      t1 = task_fixture(column, %{completed_by_agent: "Claude", needs_review: true})
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      ws_complete!(t1, 1, %{
        review_status: :approved,
        reviewed_at: now,
        reviewed_by_id: user.id
      })

      t2 = task_fixture(column, %{completed_by_agent: "Claude", needs_review: false})
      ws_complete!(t2, 1)

      # 1 changes_requested task — failure → 66.66% across the 3-task set.
      t3 = task_fixture(column, %{completed_by_agent: "Claude", needs_review: true})

      ws_complete!(t3, 1, %{
        review_status: :changes_requested,
        reviewed_at: now,
        reviewed_by_id: user.id
      })

      [%{name: "Claude", success_pct: pct, completed: completed}] =
        Workspace.agent_leaderboard(scope: scope)

      assert completed == 3
      assert_in_delta pct, 66.66, 0.5
    end

    test "is empty when no completed tasks exist" do
      assert Workspace.agent_leaderboard(scope: Scope.for_user(user_fixture())) == []
    end
  end

  describe "cumulative_flow/1" do
    test "returns 14 snapshots with all five integer fields",
         %{} do
      %{scope: scope} = ws_setup()
      flow = Workspace.cumulative_flow(scope: scope)

      assert length(flow) == 14

      for snapshot <- flow do
        assert %Date{} = snapshot.date

        for k <- [:backlog, :ready, :doing, :review, :done] do
          assert is_integer(Map.fetch!(snapshot, k))
        end
      end
    end

    test "buckets tasks at the end-of-day cutoff", %{} do
      %{column: column, scope: scope} = ws_setup()

      # A task that's been in backlog forever (no claimed_at)
      _backlog = task_fixture(column)

      # A doing task (claimed yesterday, not completed)
      doing = task_fixture(column)
      yesterday = DateTime.add(DateTime.utc_now(), -86_400, :second)
      Tasks.update_task(doing, %{claimed_at: yesterday})

      # A done task (completed yesterday, no needs_review)
      done = task_fixture(column, %{needs_review: false})
      ws_complete!(done, 0)

      [today_snapshot] = scope |> then(&Workspace.cumulative_flow(scope: &1)) |> Enum.take(-1)

      assert today_snapshot.backlog >= 1
      assert today_snapshot.doing >= 1
      assert today_snapshot.done >= 1
      assert today_snapshot.ready == 0
    end

    test "returns 14 zero snapshots for an empty workspace" do
      flow = Workspace.cumulative_flow(scope: Scope.for_user(user_fixture()))
      assert length(flow) == 14

      for snapshot <- flow do
        assert snapshot.backlog == 0
        assert snapshot.ready == 0
        assert snapshot.doing == 0
        assert snapshot.review == 0
        assert snapshot.done == 0
      end
    end

    test "excludes archived tasks from every bucket", %{} do
      %{column: column, scope: scope} = ws_setup()

      archived = task_fixture(column)

      Tasks.update_task(archived, %{
        archived_at: DateTime.add(DateTime.utc_now(), -86_400, :second)
      })

      [today_snapshot] = scope |> then(&Workspace.cumulative_flow(scope: &1)) |> Enum.take(-1)

      # The archived task should not contribute to backlog (or any bucket).
      assert today_snapshot.backlog == 0
    end
  end

  describe "workspace reads — :window_days option" do
    test "with no :window_days every daily series keeps the 14-day default" do
      %{scope: scope} = ws_setup()

      assert length(Workspace.cycle_time_daily(scope: scope)) == 14
      assert length(Workspace.throughput_daily(scope: scope)) == 14
      assert length(Workspace.cumulative_flow(scope: scope)) == 14
    end

    test "a supported :window_days sets the daily series length" do
      %{scope: scope} = ws_setup()

      for w <- [7, 14, 30, 90] do
        assert length(Workspace.cycle_time_daily(scope: scope, window_days: w)) == w
        assert length(Workspace.throughput_daily(scope: scope, window_days: w)) == w
        assert length(Workspace.cumulative_flow(scope: scope, window_days: w)) == w
      end
    end

    test "an unsupported, nil, or absent :window_days clamps to 14" do
      %{scope: scope} = ws_setup()

      for bad <- [5, 1000, :foo, nil] do
        assert length(Workspace.cycle_time_daily(scope: scope, window_days: bad)) == 14
        assert length(Workspace.throughput_daily(scope: scope, window_days: bad)) == 14
        assert length(Workspace.cumulative_flow(scope: scope, window_days: bad)) == 14
      end

      # An out-of-range window yields exactly the default-window result.
      assert Workspace.cycle_time_daily(scope: scope, window_days: 5) ==
               Workspace.cycle_time_daily(scope: scope)
    end

    test "throughput_daily zero-path respects the resolved window" do
      scope = Scope.for_user(user_fixture())

      assert Workspace.throughput_daily(scope: scope, window_days: 7) == List.duplicate(0, 7)
      assert Workspace.throughput_daily(scope: scope, window_days: 5) == List.duplicate(0, 14)
    end

    test "the window bounds which completions are counted, not just the series length" do
      %{column: column, scope: scope} = ws_setup()

      # 2 completions inside every window, 1 completion only inside 30/90.
      Enum.each(1..2, fn _ -> column |> task_fixture() |> ws_complete!(1) end)
      column |> task_fixture() |> ws_complete!(20)

      within_7 = Workspace.throughput_daily(scope: scope, window_days: 7)
      within_default = Workspace.throughput_daily(scope: scope)
      within_30 = Workspace.throughput_daily(scope: scope, window_days: 30)

      assert Enum.sum(within_7) == 2
      assert Enum.sum(within_default) == 2
      assert Enum.sum(within_30) == 3
    end

    test "workspace_kpis throughput_per_day divides by the resolved window" do
      %{column: column, scope: scope} = ws_setup()

      Enum.each(1..3, fn _ -> column |> task_fixture() |> ws_complete!(1) end)

      assert_in_delta Workspace.workspace_kpis(scope: scope, window_days: 7).throughput_per_day,
                      3 / 7,
                      0.001

      assert_in_delta Workspace.workspace_kpis(scope: scope).throughput_per_day, 3 / 14, 0.001
    end

    test "workspace_kpis deltas use the matching previous window of the same length" do
      %{column: column, scope: scope} = ws_setup()

      # 3 completions a day ago, 1 completion ten days ago.
      Enum.each(1..3, fn _ -> column |> task_fixture() |> ws_complete!(1) end)
      column |> task_fixture() |> ws_complete!(10)

      # window 7: current = 3 (day-1), previous (days 7–14) = 1 (day-10) → +200%.
      assert_in_delta Workspace.workspace_kpis(scope: scope, window_days: 7).throughput_delta_pct,
                      200.0,
                      0.1

      # window 30: both completions fall inside the current window, previous is
      # empty → divide-by-zero guard collapses the delta to 0.0.
      assert Workspace.workspace_kpis(scope: scope, window_days: 30).throughput_delta_pct == 0.0
    end

    test "agent_leaderboard counts only completions inside the resolved window" do
      %{column: column, scope: scope} = ws_setup()

      column |> task_fixture(%{completed_by_agent: "Claude"}) |> ws_complete!(1)
      column |> task_fixture(%{completed_by_agent: "Claude"}) |> ws_complete!(20)

      assert [%{name: "Claude", completed: 1}] =
               Workspace.agent_leaderboard(scope: scope, window_days: 7)

      assert [%{name: "Claude", completed: 2}] =
               Workspace.agent_leaderboard(scope: scope, window_days: 30)
    end

    test "cumulative_flow returns one snapshot per day of the resolved window" do
      %{scope: scope} = ws_setup()

      flow = Workspace.cumulative_flow(scope: scope, window_days: 90)
      assert length(flow) == 90

      for snapshot <- flow do
        assert %Date{} = snapshot.date

        for k <- [:backlog, :ready, :doing, :review, :done] do
          assert is_integer(Map.fetch!(snapshot, k))
        end
      end
    end
  end

  describe "cross-timezone correctness audit (W1268)" do
    test "workspace cycle-time median is zone-independent for mid-window completions" do
      %{column: column, scope: scope} = ws_setup()
      Enum.each([3, 4, 5], fn days_ago -> column |> task_fixture() |> ws_complete!(days_ago) end)

      edmonton = Workspace.workspace_kpis(scope: scope, timezone: "America/Edmonton")
      auckland = Workspace.workspace_kpis(scope: scope, timezone: "Pacific/Auckland")

      # ws_complete! sets a 60-minute cycle; the median is the same in every zone.
      assert edmonton.cycle_time_median_minutes == 60
      assert edmonton.cycle_time_median_minutes == auckland.cycle_time_median_minutes
    end

    test "throughput_daily and cumulative_flow fall back to Etc/UTC for an unknown zone" do
      %{column: column, scope: scope} = ws_setup()
      column |> task_fixture() |> ws_complete!(2)

      assert Workspace.throughput_daily(scope: scope, timezone: "Not/AZone") ==
               Workspace.throughput_daily(scope: scope)

      assert Workspace.cumulative_flow(scope: scope, timezone: "Not/AZone") ==
               Workspace.cumulative_flow(scope: scope)
    end
  end

  describe "workspace reads with no arguments (opts default)" do
    test "every read returns its empty/zero shape without a scope" do
      assert Workspace.workspace_kpis() == %{
               cycle_time_median_minutes: 0,
               cycle_time_delta_pct: 0.0,
               lead_time_p75_minutes: 0,
               lead_time_delta_pct: 0.0,
               throughput_per_day: 0.0,
               throughput_delta_pct: 0.0,
               review_wait_minutes: 0,
               review_wait_delta_pct: 0.0
             }

      cycle = Workspace.cycle_time_daily()
      assert length(cycle) == 14
      assert Enum.all?(cycle, &(&1.minutes == 0))

      assert Workspace.throughput_daily() == List.duplicate(0, 14)
      assert Workspace.agent_leaderboard() == []

      flow = Workspace.cumulative_flow()
      assert length(flow) == 14

      assert Enum.all?(flow, fn snap ->
               snap.backlog == 0 and snap.ready == 0 and snap.doing == 0 and
                 snap.review == 0 and snap.done == 0
             end)
    end
  end

  describe "workspace_kpis/1 — review wait and unclaimed completions" do
    test "review_wait_minutes is the median wait for reviewed needs_review tasks" do
      %{column: column, scope: scope, user: user} = ws_setup()
      task = task_fixture(column, %{needs_review: true})
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      completed_at = DateTime.add(now, -2 * 86_400, :second)
      # Reviewed 90 minutes after completion.
      reviewed_at = DateTime.add(completed_at, 90 * 60, :second)

      {:ok, _} =
        Tasks.update_task(task, %{
          claimed_at: DateTime.add(completed_at, -3600, :second),
          completed_at: completed_at,
          reviewed_at: reviewed_at,
          review_status: :approved,
          reviewed_by_id: user.id
        })

      kpis = Workspace.workspace_kpis(scope: scope)
      assert kpis.review_wait_minutes == 90
    end

    test "a completion without a claimed_at contributes no cycle time" do
      %{column: column, scope: scope} = ws_setup()
      task = task_fixture(column)
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      completed_at = DateTime.add(now, -2 * 86_400, :second)

      {:ok, _} = Tasks.update_task(task, %{completed_at: completed_at})

      kpis = Workspace.workspace_kpis(scope: scope)
      # No claimed_at → cycle_minutes is nil for the task, so the median is 0...
      assert kpis.cycle_time_median_minutes == 0
      # ...while the completion still counts toward throughput.
      assert kpis.throughput_per_day > 0.0
    end
  end

  describe "agent_leaderboard/1 — human contributor naming" do
    test "a human contributor with a name is listed under that name" do
      %{column: column, scope: scope, user: user} = ws_setup()

      {:ok, named_user} =
        user
        |> Ecto.Changeset.change(%{name: "Grace Hopper"})
        |> Kanban.Repo.update()

      task = task_fixture(column)
      ws_complete!(task, 1, %{completed_by_id: named_user.id})

      assert [%{kind: :human, name: "Grace Hopper"}] = Workspace.agent_leaderboard(scope: scope)
    end
  end

  describe "cumulative_flow/1 — review and done transitions" do
    test "a reviewed needs_review task moves from review to done at its reviewed_at day" do
      %{column: column, scope: scope, user: user} = ws_setup()
      task = task_fixture(column, %{needs_review: true})
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      completed_at = DateTime.add(now, -5 * 86_400, :second)
      reviewed_at = DateTime.add(now, -2 * 86_400, :second)

      {:ok, _} =
        Tasks.update_task(task, %{
          claimed_at: DateTime.add(completed_at, -3600, :second),
          completed_at: completed_at,
          reviewed_at: reviewed_at,
          review_status: :approved,
          reviewed_by_id: user.id
        })

      flow = Workspace.cumulative_flow(scope: scope)
      completed_date = DateTime.to_date(completed_at)
      reviewed_date = DateTime.to_date(reviewed_at)

      in_review = Enum.find(flow, &(&1.date == completed_date))
      done = Enum.find(flow, &(&1.date == reviewed_date))

      # Between completion and review the task sits in the review bucket...
      assert in_review.review == 1
      assert in_review.done == 0
      # ...and lands in done once reviewed_at has passed.
      assert done.review == 0
      assert done.done == 1
    end
  end

  describe "overview/1 — consolidated read" do
    setup do
      ctx = ws_setup()
      seed_overview_dataset(ctx)
      ctx
    end

    test "returns all five payloads", %{scope: scope} do
      overview = Workspace.overview(scope: scope)

      assert Map.keys(overview) |> Enum.sort() ==
               [:cycle_series, :flow_snapshots, :kpis, :leaderboard, :throughput_series]
    end

    test "each payload equals the individual public function for the same opts", %{scope: scope} do
      assert_overview_matches(scope: scope)
    end

    test "equivalence holds across every allowed :window_days", %{scope: scope} do
      for window_days <- [7, 14, 30, 90] do
        assert_overview_matches(scope: scope, window_days: window_days)
      end
    end

    test "equivalence holds for a non-UTC timezone", %{scope: scope} do
      assert_overview_matches(scope: scope, timezone: "America/Edmonton")
    end

    test "KPI deltas compare the current window against the previous window", %{scope: scope} do
      # The shared fetch must retain both windows: a non-zero previous window is
      # what makes the delta percentages defined (a zero previous collapses to 0.0).
      overview = Workspace.overview(scope: scope)

      assert overview.kpis == Workspace.workspace_kpis(scope: scope)
      assert overview.kpis.throughput_per_day > 0.0
      assert is_float(overview.kpis.throughput_delta_pct)
    end

    test "leaderboard resolves human names via the join, with email fallback", %{scope: scope} do
      names =
        Workspace.overview(scope: scope).leaderboard
        |> Enum.filter(&(&1.kind == :human))
        |> Enum.map(& &1.name)

      # One human has a name; the other has none, so the join's email is used.
      assert "Grace Hopper" in names
      assert Enum.any?(names, &String.contains?(&1, "@"))
    end

    test "goal-typed completions stay excluded from every derived series", %{
      column: column,
      scope: scope
    } do
      before = Workspace.overview(scope: scope)

      # A goal gets a completed_at when its last child finishes; it must never
      # count toward throughput, cycle time or the leaderboard.
      column |> task_fixture(%{type: :goal, completed_by_agent: "Claude"}) |> ws_complete!(1)

      after_goal = Workspace.overview(scope: scope)

      assert after_goal.throughput_series == before.throughput_series
      assert after_goal.cycle_series == before.cycle_series
      assert after_goal.leaderboard == before.leaderboard
      # And it still matches the individual reads, which exclude goals identically.
      assert_overview_matches(scope: scope)
    end

    test "the completed-task data comes from a single query and boards are listed once", %{
      scope: scope
    } do
      {_overview, queries} = queries_during(fn -> Workspace.overview(scope: scope) end)

      task_queries = Enum.filter(queries, fn {source, _sql} -> source == "tasks" end)

      completed_data_queries =
        Enum.filter(queries, fn {_source, sql} ->
          is_binary(sql) and String.contains?(sql, ~s(JOIN "users"))
        end)

      board_queries = Enum.filter(queries, fn {source, _sql} -> source == "boards" end)

      # Exactly one query carries the completed-task data (the projection that
      # left-joins the completing user); the second tasks query is
      # cumulative_flow's separate read, which this task intentionally leaves as-is.
      assert length(completed_data_queries) == 1
      assert length(task_queries) == 2
      # Boards.list_boards runs at most once per overview call.
      assert length(board_queries) == 1
    end
  end

  describe "overview/1 — zero shapes" do
    test "a nil scope returns the zero shape without querying" do
      {overview, queries} = queries_during(fn -> Workspace.overview([]) end)

      assert overview == Workspace.overview(scope: nil)
      assert overview.kpis == Workspace.workspace_kpis([])
      assert overview.cycle_series == Workspace.cycle_time_daily([])
      assert overview.throughput_series == Workspace.throughput_daily([])
      assert overview.leaderboard == Workspace.agent_leaderboard([])
      assert overview.flow_snapshots == Workspace.cumulative_flow([])
      assert queries == []
    end

    test "an empty board_ids filter returns the zero shape" do
      %{scope: scope} = ws_setup()
      # An empty visible board set (no boards created here beyond the setup's one,
      # but a board_ids filter that intersects to empty) yields zero shapes.
      opts = [scope: scope, board_ids: [-1]]

      overview = Workspace.overview(opts)

      assert overview.kpis == Workspace.workspace_kpis(opts)
      assert overview.throughput_series == Workspace.throughput_daily(opts)
      assert overview.leaderboard == []
    end
  end

  # --- overview/1 test helpers ----------------------------------------------

  # Seeds a mixed dataset spanning the current and previous 14-day KPI windows:
  # agent + human completions in the current window (one human named, one relying
  # on the email fallback), a reviewed needs_review task, and two previous-window
  # completions so the KPI deltas are defined.
  defp seed_overview_dataset(%{column: column, user: user}) do
    seed_current_window_completions(column, user)
    seed_reviewed_task(column, user)
    seed_previous_window_completions(column)
    :ok
  end

  defp seed_current_window_completions(column, user) do
    {:ok, named_user} =
      user |> Ecto.Changeset.change(%{name: "Grace Hopper"}) |> Kanban.Repo.update()

    email_only_user = user_fixture()

    Enum.each(1..3, fn i ->
      column |> task_fixture(%{completed_by_agent: "Claude"}) |> ws_complete!(i)
    end)

    column |> task_fixture() |> ws_complete!(1, %{completed_by_id: named_user.id})
    column |> task_fixture() |> ws_complete!(2, %{completed_by_id: email_only_user.id})
  end

  defp seed_reviewed_task(column, user) do
    reviewed = task_fixture(column, %{needs_review: true})
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    completed_at = DateTime.add(now, -2 * 86_400, :second)

    {:ok, _} =
      Tasks.update_task(reviewed, %{
        claimed_at: DateTime.add(completed_at, -3600, :second),
        completed_at: completed_at,
        reviewed_at: DateTime.add(completed_at, 90 * 60, :second),
        review_status: :approved,
        reviewed_by_id: user.id
      })
  end

  defp seed_previous_window_completions(column) do
    column |> task_fixture(%{completed_by_agent: "Claude"}) |> ws_complete!(16)
    column |> task_fixture(%{completed_by_agent: "Ada"}) |> ws_complete!(18)
  end

  defp assert_overview_matches(opts) do
    overview = Workspace.overview(opts)

    assert overview.kpis == Workspace.workspace_kpis(opts)
    assert overview.cycle_series == Workspace.cycle_time_daily(opts)
    assert overview.throughput_series == Workspace.throughput_daily(opts)
    assert overview.leaderboard == Workspace.agent_leaderboard(opts)
    assert overview.flow_snapshots == Workspace.cumulative_flow(opts)

    overview
  end

  # Counts the SQL queries Ecto emits while `fun` runs, returning
  # `{result, [{source, sql}, ...]}` so a test can assert how many fired.
  defp queries_during(fun) do
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      {:overview_query_counter, ref},
      [:kanban, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        send(parent, {ref, metadata[:source], metadata[:query]})
      end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach({:overview_query_counter, ref})
      end

    {result, collect_queries(ref)}
  end

  defp collect_queries(ref) do
    receive do
      {^ref, source, sql} -> [{source, sql} | collect_queries(ref)]
    after
      0 -> []
    end
  end
end
