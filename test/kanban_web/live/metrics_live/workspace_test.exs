defmodule KanbanWeb.MetricsLive.WorkspaceTest do
  @moduledoc """
  Integration tests for `KanbanWeb.MetricsLive.Workspace` — the
  workspace-level Metrics page at `/metrics`.
  """
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Tasks

  describe "unauthenticated access" do
    test "redirects to the log-in page when the user is not signed in", %{conn: conn} do
      assert {:error, {:redirect, %{to: redirect_to}}} = live(conn, ~p"/metrics")
      assert redirect_to =~ "/users/log-in"
    end
  end

  describe "mount and route" do
    setup [:register_and_log_in_user]

    test "authenticated user gets 200 and the page renders every component marker",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/metrics")

      assert html =~ "data-metrics-workspace"
      assert html =~ "data-metrics-header"
      assert html =~ "data-metrics-kpi-strip"
      assert html =~ "data-metrics-cycle-time-chart"
      assert html =~ "data-metrics-throughput-chart"
      assert html =~ "data-metrics-agent-leaderboard"
      assert html =~ "data-metrics-cumulative-flow"
    end

    test "the header and the throughput/leaderboard row are mobile-responsive (W1393)",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/metrics")

      # The header (title + window label + board/time-range selectors) wraps so
      # the filter controls drop to their own line on a phone instead of
      # overflowing in one row.
      assert html =~ "flex flex-wrap items-baseline gap-3 px-3 md:px-7"

      # The throughput chart + agent leaderboard stack vertically on mobile and
      # sit side by side only at md+ — so neither forces horizontal overflow at
      # 375px.
      assert html =~ "flex flex-col md:grid md:grid-cols-[1.4fr_1fr]"
    end

    test "renders the breadcrumbs Workspace > Metrics", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/metrics")
      assert html =~ "Workspace"
      assert html =~ "Metrics"
    end

    test "assigns the viewer timezone, defaulting to Etc/UTC without a tz connect param",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/metrics")

      assert :sys.get_state(view.pid).socket.assigns.timezone == "Etc/UTC"
    end

    test "renders no decorative placeholder toolbar buttons — only the working selectors",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/metrics")

      # The board and time-range controls are now real selectors and the
      # non-functional "Filter" placeholder has been removed (W1261).
      assert Regex.scan(~r/<button[^>]*data-metrics-toolbar-placeholder[^>]*>/, html) == []
      refute html =~ "data-metrics-toolbar-placeholder"
      # The capitalized "Filter" label is gone (the lowercase "board-filter-form"
      # id is unrelated and unaffected).
      refute html =~ "Filter"

      assert html =~ "data-metrics-board-selector"
      assert html =~ "data-metrics-window-selector"
    end

    test "renders the empty-workspace zero shape across every component",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/metrics")

      # KPI strip with zero values renders em-dashes for deltas.
      assert html =~ "data-metrics-kpi-cell=\"cycle-time\""
      # Leaderboard empty state.
      assert html =~ "data-metrics-agent-leaderboard-empty"
    end
  end

  describe "connected-mount gating (D120/W1732)" do
    setup [:register_and_log_in_user]

    test "the disconnected static render shows the zero state; the connected mount loads the data",
         %{conn: conn, user: user} do
      column = user |> board_fixture() |> column_fixture()
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      completed_at = DateTime.add(now, -3600, :second)
      claimed_at = DateTime.add(completed_at, -3600, :second)

      Enum.each(1..2, fn _ ->
        t = task_fixture(column, %{completed_by_agent: "Zeta"})
        {:ok, _} = Tasks.update_task(t, %{claimed_at: claimed_at, completed_at: completed_at})
      end)

      # Disconnected static render: the heavy metric read is gated off, so the
      # leaderboard shows its empty state and the seeded agent does NOT appear.
      static_html = conn |> get(~p"/metrics") |> html_response(200)
      assert static_html =~ "data-metrics-workspace"
      assert static_html =~ "data-metrics-agent-leaderboard-empty"
      refute static_html =~ "Zeta"

      # Connected mount: the real load runs and surfaces the seeded data.
      {:ok, _view, html} = live(conn, ~p"/metrics")
      assert html =~ "Zeta"
      refute html =~ "data-metrics-agent-leaderboard-empty"
    end

    test "a window change still re-renders through the single overview path",
         %{conn: conn, user: user} do
      column = user |> board_fixture() |> column_fixture()
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      completed_at = DateTime.add(now, -3600, :second)
      claimed_at = DateTime.add(completed_at, -3600, :second)
      t = task_fixture(column, %{completed_by_agent: "Zeta"})
      {:ok, _} = Tasks.update_task(t, %{claimed_at: claimed_at, completed_at: completed_at})

      {:ok, view, _html} = live(conn, ~p"/metrics")

      html =
        view
        |> element("#window-days-form")
        |> render_change(%{"window_days" => "30"})

      assert html =~ "Zeta"
      # 30-day window renders 30 throughput points.
      assert length(Regex.scan(~r/data-metrics-throughput-point/, html)) == 30
    end
  end

  # W1719: the cycle time chart's y-axis is fitted to the data it plots
  # instead of a fixed 0/50/100/150 tick list on a 150-minute floor.
  describe "cycle time chart scale" do
    setup [:register_and_log_in_user]

    test "renders gridlines derived from the plotted series rather than a fixed scale",
         %{conn: conn, user: user} do
      column = user |> board_fixture() |> column_fixture()
      seed_cycle_time(column, minutes: 60, days_ago: 0)

      {:ok, _view, html} = live(conn, ~p"/metrics")

      # A 60-minute median scales to a 60-minute maximum in 20m steps.
      assert html =~ ~s(data-metrics-cycle-time-gridline="60")
      refute html =~ ~s(data-metrics-cycle-time-gridline="150")
    end

    test "renders a trend line over the cycle time chart", %{conn: conn, user: user} do
      column = user |> board_fixture() |> column_fixture()
      # Two days with different medians, so the regression has a line to fit.
      seed_cycle_time(column, minutes: 10, days_ago: 0)
      seed_cycle_time(column, minutes: 40, days_ago: 2)

      {:ok, _view, html} = live(conn, ~p"/metrics")

      assert html =~ "data-metrics-cycle-time-trend"
      assert html =~ "data-metrics-cycle-time-trend-line"
    end

    test "refits the scale when the window selector changes the plotted series",
         %{conn: conn, user: user} do
      column = user |> board_fixture() |> column_fixture()
      seed_cycle_time(column, minutes: 30, days_ago: 0)
      seed_cycle_time(column, minutes: 300, days_ago: 40)

      {:ok, view, html} = live(conn, ~p"/metrics")

      # The default window sees only the recent 30-minute day.
      assert html =~ ~s(data-metrics-cycle-time-gridline="30")
      refute html =~ ~s(data-metrics-cycle-time-gridline="300")

      widened =
        view
        |> element("#window-days-form")
        |> render_change(%{"window_days" => "90"})

      # Widening pulls in the 300-minute day, and the axis grows to match.
      assert widened =~ ~s(data-metrics-cycle-time-gridline="300")
      refute widened =~ ~s(data-metrics-cycle-time-gridline="30")
    end
  end

  describe "data wiring" do
    setup [:register_and_log_in_user]

    test "aggregates workspace metrics across the user's boards",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      completed_at = DateTime.add(now, -1 * 3600, :second)
      claimed_at = DateTime.add(completed_at, -60 * 60, :second)

      Enum.each(1..2, fn _ ->
        t = task_fixture(column, %{completed_by_agent: "Claude"})

        {:ok, _} =
          Tasks.update_task(t, %{
            claimed_at: claimed_at,
            completed_at: completed_at
          })
      end)

      {:ok, _view, html} = live(conn, ~p"/metrics")

      # The agent leaderboard surfaces Claude with 2 completions.
      assert html =~ "Claude"
      # The throughput chart renders the per-point circles for the 14 days.
      assert length(Regex.scan(~r/data-metrics-throughput-point/, html)) == 14
    end

    test "uses :metrics as the active side-nav item", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/metrics")
      assert html =~ "Metrics"
    end
  end

  describe "board selector" do
    setup [:register_and_log_in_user]

    # Completes `count` tasks on `column` credited to `agent`, so the agent
    # leaderboard surfaces that name for the board the column belongs to.
    defp complete_on(column, agent, count) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      completed_at = DateTime.add(now, -3600, :second)
      claimed_at = DateTime.add(completed_at, -3600, :second)

      Enum.each(1..count, fn _ ->
        t = task_fixture(column, %{completed_by_agent: agent})
        {:ok, _} = Tasks.update_task(t, %{claimed_at: claimed_at, completed_at: completed_at})
      end)
    end

    defp checked_board_boxes(html) do
      Regex.scan(~r/name="board_ids\[\]"[^>]*checked/, html)
    end

    test "defaults to all of the user's boards selected with an 'All boards' summary",
         %{conn: conn, user: user} do
      board_fixture(user)
      board_fixture(user)

      {:ok, _view, html} = live(conn, ~p"/metrics")

      assert html =~ "data-metrics-board-selector"
      assert html =~ "All boards"
      assert length(checked_board_boxes(html)) == 2
    end

    test "selecting a strict subset re-renders metrics using only those boards' data",
         %{conn: conn, user: user} do
      board1 = board_fixture(user)
      board2 = board_fixture(user)
      complete_on(column_fixture(board1), "AlphaAgent", 1)
      complete_on(column_fixture(board2), "BetaAgent", 1)

      {:ok, view, html} = live(conn, ~p"/metrics")
      assert html =~ "AlphaAgent"
      assert html =~ "BetaAgent"

      html =
        view
        |> element("#board-filter-form")
        |> render_change(%{"board_ids" => [to_string(board1.id)]})

      assert html =~ "AlphaAgent"
      refute html =~ "BetaAgent"
    end

    test "the toolbar and window label reflect the selected-board count",
         %{conn: conn, user: user} do
      board1 = board_fixture(user)
      _board2 = board_fixture(user)

      {:ok, view, html} = live(conn, ~p"/metrics")
      assert html =~ "all boards"

      html =
        view
        |> element("#board-filter-form")
        |> render_change(%{"board_ids" => [to_string(board1.id)]})

      # window_label (lowercase) and the selector summary both update.
      assert html =~ "1 board"
      assert html =~ "1 of 2 boards"
    end

    test "clearing the selection falls back to all visible boards",
         %{conn: conn, user: user} do
      board1 = board_fixture(user)
      board2 = board_fixture(user)
      complete_on(column_fixture(board1), "AlphaAgent", 1)
      complete_on(column_fixture(board2), "BetaAgent", 1)

      {:ok, view, _html} = live(conn, ~p"/metrics")

      html =
        view
        |> element("#board-filter-form")
        |> render_change(%{})

      # No board_ids key => the page shows all visible boards, not an empty page.
      assert html =~ "AlphaAgent"
      assert html =~ "BetaAgent"
      assert html =~ "all boards"
    end

    test "a fresh mount resets the selection to all boards (session-only)",
         %{conn: conn, user: user} do
      board1 = board_fixture(user)
      board_fixture(user)

      {:ok, view, _html} = live(conn, ~p"/metrics")

      view
      |> element("#board-filter-form")
      |> render_change(%{"board_ids" => [to_string(board1.id)]})

      # A page reload is a fresh mount — selection resets to all boards.
      {:ok, _view2, html2} = live(conn, ~p"/metrics")
      assert html2 =~ "All boards"
      assert length(checked_board_boxes(html2)) == 2
    end

    test "renders gracefully for a user with no boards",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/metrics")

      assert html =~ "data-metrics-board-selector"
      assert html =~ "No boards yet"
      assert html =~ "All boards"
    end
  end

  describe "time-range selector" do
    setup [:register_and_log_in_user]

    defp selected_window(html) do
      case Regex.run(~r/<option value="(\d+)"\s+selected/, html) do
        [_, days] -> String.to_integer(days)
        _ -> nil
      end
    end

    test "defaults to a 14-day window and offers 7/14/30/90 options",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/metrics")

      assert html =~ "data-metrics-window-selector"
      assert selected_window(html) == 14

      assert html =~ "Last 7 days"
      assert html =~ "Last 14 days"
      assert html =~ "Last 30 days"
      assert html =~ "Last 90 days"
    end

    test "selecting a 7-day window re-renders every series and label with that window",
         %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/metrics")

      # Default 14-day window: 14 throughput points and 14-day subtitles.
      assert length(Regex.scan(~r/data-metrics-throughput-point/, html)) == 14
      assert html =~ "14 days"

      html =
        view
        |> element("#window-days-form")
        |> render_change(%{"window_days" => "7"})

      assert selected_window(html) == 7
      assert length(Regex.scan(~r/data-metrics-throughput-point/, html)) == 7
      # Throughput, cycle-time, leaderboard, and KPI subtitles all follow.
      assert html =~ "7 days"
      # The cycle-time chart is now a single series — no agent/human split.
      refute html =~ "agent vs human"
      assert html =~ "Agents · last 7 days"
      assert html =~ "vs prev 7d"
      refute html =~ "vs prev 14d"
    end

    test "selecting a 30-day window updates the series length and subtitles",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/metrics")

      html =
        view
        |> element("#window-days-form")
        |> render_change(%{"window_days" => "30"})

      assert selected_window(html) == 30
      assert length(Regex.scan(~r/data-metrics-throughput-point/, html)) == 30
      assert html =~ "30 days"
      assert html =~ "vs prev 30d"
    end

    test "a forged window value falls back to the 14-day default",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/metrics")

      html =
        view
        |> element("#window-days-form")
        |> render_change(%{"window_days" => "999"})

      assert selected_window(html) == 14
      assert length(Regex.scan(~r/data-metrics-throughput-point/, html)) == 14
      assert html =~ "14 days"
    end

    test "a fresh mount resets the window to 14 days (session-only)",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/metrics")

      view
      |> element("#window-days-form")
      |> render_change(%{"window_days" => "90"})

      # A page reload is a fresh mount — the window resets to 14 days.
      {:ok, _view2, html2} = live(conn, ~p"/metrics")
      assert selected_window(html2) == 14
      refute html2 =~ "Agents · last 90 days"
    end

    test "the window selection survives a board-filter change",
         %{conn: conn, user: user} do
      board1 = board_fixture(user)
      _board2 = board_fixture(user)

      {:ok, view, _html} = live(conn, ~p"/metrics")

      view
      |> element("#window-days-form")
      |> render_change(%{"window_days" => "7"})

      # Changing the board filter must not reset the 7-day window — it is held
      # in assigns and read back by the board-filter handler.
      html =
        view
        |> element("#board-filter-form")
        |> render_change(%{"board_ids" => [to_string(board1.id)]})

      assert selected_window(html) == 7
      assert html =~ "7 days"
      assert html =~ "1 of 2 boards"
    end
  end

  # A completed task whose claimed-to-completed span is `minutes`, landing on
  # the day `days_ago` back so it falls inside or outside a chosen window.
  defp seed_cycle_time(column, opts) do
    minutes = Keyword.fetch!(opts, :minutes)
    days_ago = Keyword.fetch!(opts, :days_ago)

    completed_at =
      DateTime.utc_now()
      |> DateTime.add(-days_ago, :day)
      |> DateTime.truncate(:second)

    claimed_at = DateTime.add(completed_at, -minutes * 60, :second)

    {:ok, task} =
      column
      |> task_fixture()
      |> Tasks.update_task(%{claimed_at: claimed_at, completed_at: completed_at})

    task
  end
end
