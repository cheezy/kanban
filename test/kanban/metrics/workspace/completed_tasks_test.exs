defmodule Kanban.Metrics.Workspace.CompletedTasksTest do
  @moduledoc """
  Direct unit tests for the completed-task read behind the workspace `/metrics`
  page.

  `Kanban.Metrics.WorkspaceTest` exercises this module through the façade, which
  resolves scope and options first. These tests call it with already-resolved
  `board_ids` / `window_days` / `timezone` / `exclude_weekends?` instead, which
  reaches three things the façade path cannot:

    * the zero/placeholder functions as an independent public API, including
      whether their shapes still agree with the loaded reads they stand in for;
    * `overview_series/4`'s window partitioning at the exact boundary instant;
    * the leaderboard's contributor-classification edge cases, which need a
      task shape the changeset will not produce.

  Every window here is a TRAILING window anchored on local today, so all fixture
  timestamps are relative — a fixed literal date would fall outside the window
  and every assertion would silently read zero.
  """
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Metrics.Workspace.CompletedTasks
  alias Kanban.Metrics.Workspace.Windows
  alias Kanban.Repo
  alias Kanban.Tasks

  @utc "Etc/UTC"
  @window 14

  defp ws_setup do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board)
    %{user: user, board: board, column: column, board_ids: [board.id]}
  end

  # Completes a task `days_ago`, with a one-hour cycle by default.
  defp complete!(task, days_ago, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    completed_at = DateTime.add(now, -days_ago * 86_400, :second)
    claimed_at = DateTime.add(completed_at, -3600, :second)

    {:ok, t} =
      Tasks.update_task(
        task,
        Map.merge(%{claimed_at: claimed_at, completed_at: completed_at}, Map.new(attrs))
      )

    t
  end

  # Sets fields the changeset will not cast (or would normalize away).
  defp put_fields!(task, fields) do
    {:ok, t} = task |> Ecto.Changeset.change(fields) |> Repo.update()
    t
  end

  describe "zero_kpis/0" do
    test "every value is a zero of the right numeric kind" do
      kpis = CompletedTasks.zero_kpis()

      assert kpis.cycle_time_median_minutes == 0
      assert kpis.lead_time_p50_minutes == 0
      assert kpis.review_wait_minutes == 0
      assert kpis.throughput_per_day == 0.0
      assert kpis.cycle_time_delta_pct == 0.0
      assert kpis.lead_time_delta_pct == 0.0
      assert kpis.throughput_delta_pct == 0.0
      assert kpis.review_wait_delta_pct == 0.0
    end

    test "carries exactly the keys a loaded kpis/4 returns" do
      # The zero map stands in for a real read on the empty path. If the two key
      # sets drift, the metrics page renders a missing-key crash for exactly the
      # users who have no data yet — the ones least able to report it.
      %{column: column, board_ids: board_ids} = ws_setup()
      column |> task_fixture() |> complete!(1)

      loaded = CompletedTasks.kpis(board_ids, @window, @utc)

      assert Map.keys(CompletedTasks.zero_kpis()) == Map.keys(loaded)
    end
  end

  describe "placeholder series agree with the loaded series they stand in for" do
    setup do
      context = ws_setup()
      context.column |> task_fixture() |> complete!(1)
      context
    end

    test "empty_cycle_series matches cycle_time_daily's length in both weekend modes",
         %{board_ids: board_ids} do
      for exclude? <- [false, true] do
        placeholder = CompletedTasks.empty_cycle_series(@window, @utc, exclude?)
        loaded = CompletedTasks.cycle_time_daily(board_ids, @window, @utc, exclude?)

        assert length(placeholder) == length(loaded)
        assert Enum.map(placeholder, & &1.date) == Enum.map(loaded, & &1.date)
      end
    end

    test "empty_lead_series matches lead_time_daily's length in both weekend modes",
         %{board_ids: board_ids} do
      for exclude? <- [false, true] do
        placeholder = CompletedTasks.empty_lead_series(@window, @utc, exclude?)
        loaded = CompletedTasks.lead_time_daily(board_ids, @window, @utc, exclude?)

        assert length(placeholder) == length(loaded)
        assert Enum.map(placeholder, & &1.date) == Enum.map(loaded, & &1.date)
      end
    end

    test "empty_throughput_series matches throughput_daily's length in both weekend modes",
         %{board_ids: board_ids} do
      for exclude? <- [false, true] do
        placeholder = CompletedTasks.empty_throughput_series(@window, @utc, exclude?)
        loaded = CompletedTasks.throughput_daily(board_ids, @window, @utc, exclude?)

        assert length(placeholder) == length(loaded)
      end
    end

    test "the placeholders are genuinely zeroed and ordered oldest-to-newest" do
      cycle = CompletedTasks.empty_cycle_series(@window, @utc)
      dates = Enum.map(cycle, & &1.date)
      throughput = CompletedTasks.empty_throughput_series(@window, @utc)

      assert Enum.all?(cycle, &(&1.minutes == 0))
      assert dates == Enum.sort(dates, Date)
      assert Enum.all?(throughput, &(&1 == 0))
    end

    test "excluding weekends shortens the placeholder rather than shifting the window" do
      full = CompletedTasks.empty_cycle_series(@window, @utc, false)
      weekdays = CompletedTasks.empty_cycle_series(@window, @utc, true)

      assert length(weekdays) < length(full)
      assert Enum.all?(weekdays, &(Date.day_of_week(&1.date) not in [6, 7]))
      # Same span: the first and last WEEKDAY of the full range are preserved.
      assert List.first(weekdays).date in Enum.map(full, & &1.date)
      assert List.last(weekdays).date in Enum.map(full, & &1.date)
    end

    test "the placeholder respects a non-default window_days" do
      assert length(CompletedTasks.empty_cycle_series(30, @utc)) == 30
      assert length(CompletedTasks.empty_throughput_series(7, @utc)) == 7
    end
  end

  describe "the exclude_weekends? argument defaults to false" do
    setup do
      context = ws_setup()
      context.column |> task_fixture() |> complete!(1)
      context
    end

    test "on every public read", %{board_ids: board_ids} do
      assert CompletedTasks.kpis(board_ids, @window, @utc) ==
               CompletedTasks.kpis(board_ids, @window, @utc, false)

      assert CompletedTasks.cycle_time_daily(board_ids, @window, @utc) ==
               CompletedTasks.cycle_time_daily(board_ids, @window, @utc, false)

      assert CompletedTasks.lead_time_daily(board_ids, @window, @utc) ==
               CompletedTasks.lead_time_daily(board_ids, @window, @utc, false)

      assert CompletedTasks.throughput_daily(board_ids, @window, @utc) ==
               CompletedTasks.throughput_daily(board_ids, @window, @utc, false)

      assert CompletedTasks.leaderboard(board_ids, @window, @utc) ==
               CompletedTasks.leaderboard(board_ids, @window, @utc, false)

      assert CompletedTasks.overview_series(board_ids, @window, @utc) ==
               CompletedTasks.overview_series(board_ids, @window, @utc, false)
    end

    test "and on every placeholder" do
      assert CompletedTasks.empty_cycle_series(@window, @utc) ==
               CompletedTasks.empty_cycle_series(@window, @utc, false)

      assert CompletedTasks.empty_lead_series(@window, @utc) ==
               CompletedTasks.empty_lead_series(@window, @utc, false)

      assert CompletedTasks.empty_throughput_series(@window, @utc) ==
               CompletedTasks.empty_throughput_series(@window, @utc, false)
    end
  end

  describe "overview_series/4 — window partitioning" do
    test "a task completed exactly at the window boundary counts in BOTH windows" do
      # Documented invariant: the two overlapping filters (current uses
      # `>= current_start`, previous uses `<= current_start`) reproduce what the
      # original pair of separate window queries did, so a task sitting exactly
      # on the boundary lands in BOTH.
      #
      # A second task, unambiguously inside the previous window, is what makes
      # this test discriminate. Without it the previous window would be empty and
      # the delta would read 0.0 from the divide-by-zero guard whether or not the
      # boundary task was double-counted — the assertion would prove nothing.
      #
      #   boundary task: 60-minute cycle, sits on the boundary
      #   older task:   180-minute cycle, squarely in the previous window
      #
      #   counted in both (correct): previous = median(60, 180) = 120
      #                              delta = (60 - 120) / 120 = -50.0%
      #   counted only in current:   previous = median(180)     = 180
      #                              delta = (60 - 180) / 180 = -66.7%
      %{column: column, board_ids: board_ids} = ws_setup()
      boundary = Windows.local_day_start(@window - 1, @utc)

      column
      |> task_fixture()
      |> complete!(1)
      |> put_fields!(%{
        completed_at: boundary,
        claimed_at: DateTime.add(boundary, -3600, :second)
      })

      older = DateTime.add(boundary, -6 * 86_400, :second)

      column
      |> task_fixture()
      |> complete!(1)
      |> put_fields!(%{
        completed_at: older,
        claimed_at: DateTime.add(older, -180 * 60, :second)
      })

      %{kpis: kpis} = CompletedTasks.overview_series(board_ids, @window, @utc)

      assert kpis.cycle_time_median_minutes == 60
      assert_in_delta kpis.cycle_time_delta_pct, -50.0, 0.001
    end

    test "a task completed after the boundary counts only in the current window" do
      %{column: column, board_ids: board_ids} = ws_setup()

      column |> task_fixture() |> complete!(1)

      %{kpis: kpis} = CompletedTasks.overview_series(board_ids, @window, @utc)

      # Previous window is empty, so the divide-by-zero guard pins the delta at
      # 0.0 rather than an infinity.
      assert kpis.cycle_time_median_minutes == 60
      assert kpis.cycle_time_delta_pct == 0.0
      assert kpis.throughput_per_day > 0.0
    end

    test "returns all five payloads and nothing else" do
      %{column: column, board_ids: board_ids} = ws_setup()
      column |> task_fixture() |> complete!(1)

      keys =
        board_ids
        |> CompletedTasks.overview_series(@window, @utc)
        |> Map.keys()
        |> Enum.sort()

      assert keys == [:cycle_series, :kpis, :lead_series, :leaderboard, :throughput_series]
    end

    test "its series equal the individually-read series for the same arguments" do
      %{column: column, board_ids: board_ids, user: user} = ws_setup()

      column |> task_fixture(%{completed_by_agent: "Claude"}) |> complete!(1)
      column |> task_fixture() |> complete!(3, %{completed_by_id: user.id})

      overview = CompletedTasks.overview_series(board_ids, @window, @utc)

      assert overview.cycle_series == CompletedTasks.cycle_time_daily(board_ids, @window, @utc)
      assert overview.lead_series == CompletedTasks.lead_time_daily(board_ids, @window, @utc)

      assert overview.throughput_series ==
               CompletedTasks.throughput_daily(board_ids, @window, @utc)

      assert overview.leaderboard == CompletedTasks.leaderboard(board_ids, @window, @utc)
      assert overview.kpis == CompletedTasks.kpis(board_ids, @window, @utc)
    end
  end

  describe "leaderboard/4 — contributor classification" do
    test "needs_review: false makes a completion successful even when a review says otherwise" do
      # `successful_completion?/1` matches needs_review: false FIRST, so a stale
      # or contradictory review_status on a no-review task cannot drag the
      # contributor's success rate down. Not reachable through the ordinary
      # review flow, but the clause order is what guarantees it.
      %{column: column, board_ids: board_ids, user: user} = ws_setup()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      column
      |> task_fixture(%{completed_by_agent: "Claude", needs_review: false})
      |> complete!(1, %{
        review_status: :changes_requested,
        reviewed_at: now,
        reviewed_by_id: user.id
      })

      assert [%{name: "Claude", completed: 1, success_pct: 100.0}] =
               CompletedTasks.leaderboard(board_ids, @window, @utc)
    end

    test "a needs_review task with no verdict yet counts as unsuccessful" do
      %{column: column, board_ids: board_ids} = ws_setup()

      column
      |> task_fixture(%{completed_by_agent: "Claude", needs_review: true})
      |> complete!(1)

      assert [%{name: "Claude", completed: 1, success_pct: +0.0}] =
               CompletedTasks.leaderboard(board_ids, @window, @utc)
    end

    test "a task credited to an agent is not also counted for the completing human" do
      # `human_completion?/1` returns false as soon as a non-empty agent string is
      # present, so a task carrying both attributions appears once, as the agent.
      %{column: column, board_ids: board_ids, user: user} = ws_setup()

      column
      |> task_fixture(%{completed_by_agent: "Claude"})
      |> complete!(1, %{completed_by_id: user.id})

      assert [%{name: "Claude", kind: :agent, completed: 1}] =
               CompletedTasks.leaderboard(board_ids, @window, @utc)
    end

    test "a human completion with no agent is attributed to the user's name" do
      %{column: column, board_ids: board_ids, user: user} = ws_setup()

      column |> task_fixture() |> complete!(1, %{completed_by_id: user.id})

      assert [%{kind: :human, completed: 1}] =
               CompletedTasks.leaderboard(board_ids, @window, @utc)
    end

    test "a completion attributed to neither an agent nor a user is left off entirely" do
      %{column: column, board_ids: board_ids} = ws_setup()

      column |> task_fixture() |> complete!(1)

      assert CompletedTasks.leaderboard(board_ids, @window, @utc) == []
    end

    test "contributors are ordered by completion count within their kind" do
      %{column: column, board_ids: board_ids} = ws_setup()

      for _ <- 1..3, do: column |> task_fixture(%{completed_by_agent: "Busy"}) |> complete!(1)
      column |> task_fixture(%{completed_by_agent: "Quiet"}) |> complete!(1)

      assert [%{name: "Busy", completed: 3}, %{name: "Quiet", completed: 1}] =
               CompletedTasks.leaderboard(board_ids, @window, @utc)
    end

    test "completions outside the window are not counted" do
      %{column: column, board_ids: board_ids} = ws_setup()

      column |> task_fixture(%{completed_by_agent: "Claude"}) |> complete!(1)
      column |> task_fixture(%{completed_by_agent: "Claude"}) |> complete!(@window + 5)

      assert [%{name: "Claude", completed: 1}] =
               CompletedTasks.leaderboard(board_ids, @window, @utc)
    end
  end

  describe "empty board set" do
    test "every read returns its zero shape without touching a board" do
      assert CompletedTasks.kpis([], @window, @utc) == CompletedTasks.zero_kpis()
      assert CompletedTasks.leaderboard([], @window, @utc) == []

      assert CompletedTasks.cycle_time_daily([], @window, @utc) ==
               CompletedTasks.empty_cycle_series(@window, @utc)

      assert CompletedTasks.lead_time_daily([], @window, @utc) ==
               CompletedTasks.empty_lead_series(@window, @utc)

      assert CompletedTasks.throughput_daily([], @window, @utc) ==
               CompletedTasks.empty_throughput_series(@window, @utc)
    end

    test "overview_series/4 also collapses to the zero payloads" do
      result = CompletedTasks.overview_series([], @window, @utc)

      assert result.kpis == CompletedTasks.zero_kpis()
      assert result.leaderboard == []
      assert result.cycle_series == CompletedTasks.empty_cycle_series(@window, @utc)
      assert result.throughput_series == CompletedTasks.empty_throughput_series(@window, @utc)
    end
  end
end
