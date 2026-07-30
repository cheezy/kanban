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
      assert html =~ "data-metrics-lead-time-chart"
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

  # W1723: the lead-time series renders through the same chart component as the
  # cycle series, parameterized for violet, and sits directly below it.
  describe "lead time chart" do
    setup [:register_and_log_in_user]

    test "assigns :lead_series from the same overview bundle as :cycle_series",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/metrics")

      # Pitfall 1: the lead series must ride the shared options rather than a
      # second map, or it would silently ignore the board/window/timezone
      # selectors. Both assigns come from one Workspace.overview/1 call, so
      # they are necessarily the same length and window.
      assigns = :sys.get_state(view.pid).socket.assigns

      assert length(assigns.lead_series) == length(assigns.cycle_series)
      assert Enum.map(assigns.lead_series, & &1.date) == Enum.map(assigns.cycle_series, & &1.date)
    end

    test "renders directly below the cycle time chart in document order",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/metrics")

      cycle_at = :binary.match(html, "data-metrics-cycle-time-chart") |> elem(0)
      lead_at = :binary.match(html, "data-metrics-lead-time-chart") |> elem(0)
      throughput_at = :binary.match(html, "data-metrics-throughput-chart") |> elem(0)

      # Below the cycle chart, and still above the throughput/leaderboard grid
      # — i.e. in the stacked container, not inside the two-column row.
      assert cycle_at < lead_at
      assert lead_at < throughput_at
    end

    test "renders the violet accent while the cycle chart keeps the orange one",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/metrics")

      assert html =~ "var(--stride-violet)"
      assert html =~ "var(--stride-orange)"

      # Each token belongs to its own chart's bars, so the two are visually
      # distinct rather than both rendering the same accent.
      assert html =~ ~s(data-metrics-lead-time-segment="lead")
      assert html =~ ~s(data-metrics-cycle-time-segment="cycle")
    end

    test "renders the lead time title with the sibling middot convention",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/metrics")

      assert html =~ "Lead time · daily median (min)"
      # The cycle title is unchanged alongside it.
      assert html =~ "Cycle time · daily median (min)"
      # The statistic is the median, never p75.
      refute html =~ "p75"
    end

    test "passes the accent as a brand token, not a hardcoded color", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/metrics")

      # Scoped to this chart's own bars: other components on the page carry
      # their own literals, so a page-wide assertion would prove nothing here.
      lead_segments =
        Regex.scan(~r/data-metrics-lead-time-segment="lead"[^>]*style="([^"]*)"/, html)
        |> Enum.map(&List.last/1)

      assert length(lead_segments) == 14

      for style <- lead_segments do
        assert style =~ "background: var(--stride-violet)"
        refute style =~ ~r/background: #[0-9a-fA-F]{3,8}/
        refute style =~ ~r/background: oklch\(/
      end
    end

    test "an empty workspace renders the lead chart without raising", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/metrics")

      assert html =~ "data-metrics-lead-time-chart"
      assert length(Regex.scan(~r/data-metrics-lead-time-bar(?!-)/, html)) == 14
    end

    test "reflects lead times on days the cycle series reads zero", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      completed_at = DateTime.utc_now() |> DateTime.truncate(:second)

      # Completed but never claimed: it has a lead time but no cycle time.
      task = task_fixture(column)

      {:ok, task} =
        task
        |> Ecto.Changeset.change(%{completed_at: completed_at, claimed_at: nil})
        |> Kanban.Repo.update()

      # Backdate creation so the lead time is a genuine 120 minutes rather than
      # being clamped to zero by the max-of-zero guard.
      {:ok, _} =
        task
        |> Ecto.Changeset.change(%{
          inserted_at:
            completed_at
            |> DateTime.add(-120 * 60, :second)
            |> DateTime.to_naive()
            |> NaiveDateTime.truncate(:second)
        })
        |> Kanban.Repo.update()

      {:ok, _view, html} = live(conn, ~p"/metrics")

      # The lead chart scales to cover the 120-minute peak (rounding to a 150m
      # axis), while the cycle chart — the task was never claimed, so it has no
      # cycle time at all — falls back to its 0..4 empty-state axis. That
      # divergence is the whole point: lead time exists where cycle time cannot.
      assert html =~ ~s(data-metrics-lead-time-gridline="150")
      refute html =~ ~s(data-metrics-lead-time-gridline="4")
      assert html =~ ~s(data-metrics-cycle-time-gridline="4")
    end

    test "follows the board selector", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      other_board = board_fixture(user)
      completed_at = DateTime.utc_now() |> DateTime.truncate(:second)

      task = task_fixture(column)

      {:ok, task} =
        task
        |> Ecto.Changeset.change(%{completed_at: completed_at, claimed_at: nil})
        |> Kanban.Repo.update()

      {:ok, _} =
        task
        |> Ecto.Changeset.change(%{
          inserted_at:
            completed_at
            |> DateTime.add(-120 * 60, :second)
            |> DateTime.to_naive()
            |> NaiveDateTime.truncate(:second)
        })
        |> Kanban.Repo.update()

      {:ok, view, html} = live(conn, ~p"/metrics")

      # The 120-minute lead scales the axis to a 150m maximum.
      assert html =~ ~s(data-metrics-lead-time-gridline="150")

      # Filtering to the other board drops the completion, so the lead chart
      # falls back to its empty-state axis rather than ignoring the filter.
      html =
        view
        |> element("#board-filter-form")
        |> render_change(%{"board_ids" => ["#{other_board.id}"]})

      refute html =~ ~s(data-metrics-lead-time-gridline="150")
      assert html =~ ~s(data-metrics-lead-time-gridline="4")
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

    # The lead chart's own <section>, so a subtitle assertion cannot be
    # satisfied by a sibling chart's copy of the shared subtitle string.
    defp lead_chart_section(html) do
      [section] =
        Regex.run(~r/<section data-metrics-lead-time-chart.*?<\/section>/s, html)

      section
    end

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
      assert length(Regex.scan(~r/data-metrics-lead-time-bar(?!-)/, html)) == 14
      assert html =~ "14 days"

      html =
        view
        |> element("#window-days-form")
        |> render_change(%{"window_days" => "7"})

      assert selected_window(html) == 7
      assert length(Regex.scan(~r/data-metrics-throughput-point/, html)) == 7
      # The lead chart follows the window too. Its bar count carries the real
      # weight; the subtitle is asserted inside the lead chart's own section
      # rather than page-wide, since every chart shares the subtitle msgid and
      # a page-wide match would pass even with the lead subtitle stuck.
      assert length(Regex.scan(~r/data-metrics-lead-time-bar(?!-)/, html)) == 7
      assert lead_chart_section(html) =~ "last 7 days"
      # Throughput, cycle-time, lead-time, leaderboard, and KPI subtitles all follow.
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

  describe "exclude-weekends filter (W1743)" do
    setup [:register_and_log_in_user]

    defp weekend_checked?(html) do
      Regex.match?(~r/id="exclude_weekends"[^>]*\schecked/, html)
    end

    defp throughput_points(html), do: length(Regex.scan(~r/data-metrics-throughput-point/, html))
    defp lead_bars(html), do: length(Regex.scan(~r/data-metrics-lead-time-bar(?!-)/, html))

    test "renders an unchecked Exclude Weekends checkbox by default", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/metrics")

      assert html =~ "data-metrics-weekend-selector"
      assert html =~ "Exclude Weekends"
      refute weekend_checked?(html)
    end

    test "checking it drops the weekend buckets from every chart", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/metrics")

      # A 14-day window is two calendar weeks: 14 buckets, of which 10 are
      # weekdays — so the counts below hold whichever day the suite runs on.
      assert throughput_points(html) == 14
      assert lead_bars(html) == 14

      html =
        view
        |> element("#weekend-filter-form")
        |> render_change(%{"exclude_weekends" => "true"})

      assert weekend_checked?(html)
      assert throughput_points(html) == 10
      assert lead_bars(html) == 10
    end

    test "the subtitle keeps naming calendar days even though fewer bars render",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/metrics")

      html =
        view
        |> element("#weekend-filter-form")
        |> render_change(%{"exclude_weekends" => "true"})

      # 10 bars under a "last 14 days" subtitle is intentional: window_days
      # means CALENDAR days, and excluding weekends removes days rather than
      # reaching further back. Asserted explicitly so it is not "fixed" later.
      assert lead_bars(html) == 10
      assert lead_chart_section(html) =~ "last 14 days"
      assert html =~ "14 days"
    end

    test "unchecking restores the full window", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/metrics")

      view
      |> element("#weekend-filter-form")
      |> render_change(%{"exclude_weekends" => "true"})

      # An unchecked box omits the key entirely — this is the payload the
      # browser actually sends, and it must parse back to false. The event is
      # sent to the view directly rather than through element/2, because
      # element-based render_change merges the params with the rendered DOM,
      # which still carries checked="checked" and would mask the omission.
      html = render_change(view, "weekend_filter_change", %{})

      refute weekend_checked?(html)
      assert throughput_points(html) == 14
      assert lead_bars(html) == 14
    end

    test "composes with the window selector", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/metrics")

      view
      |> element("#window-days-form")
      |> render_change(%{"window_days" => "7"})

      html =
        view
        |> element("#weekend-filter-form")
        |> render_change(%{"exclude_weekends" => "true"})

      # A 7-day window always contains exactly 5 weekdays.
      assert selected_window(html) == 7
      assert throughput_points(html) == 5
      assert lead_bars(html) == 5
    end

    test "the selection survives a board-filter change", %{conn: conn, user: user} do
      board1 = board_fixture(user)
      _board2 = board_fixture(user)

      {:ok, view, _html} = live(conn, ~p"/metrics")

      view
      |> element("#weekend-filter-form")
      |> render_change(%{"exclude_weekends" => "true"})

      html =
        view
        |> element("#board-filter-form")
        |> render_change(%{"board_ids" => [to_string(board1.id)]})

      assert weekend_checked?(html)
      assert throughput_points(html) == 10
      assert html =~ "1 of 2 boards"
    end

    test "a fresh mount resets the checkbox (session-only)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/metrics")

      view
      |> element("#weekend-filter-form")
      |> render_change(%{"exclude_weekends" => "true"})

      # A page reload is a fresh mount — the filter resets, matching the board
      # metrics pages (no push_patch, no URL persistence).
      {:ok, _view2, html2} = live(conn, ~p"/metrics")

      refute weekend_checked?(html2)
      assert throughput_points(html2) == 14
    end
  end

  describe "cumulative-flow Done-band toggle (W1956)" do
    setup [:register_and_log_in_user]

    defp cfd_done_checked?(html) do
      Regex.match?(~r/id="cfd_show_done"[^>]*\schecked/, html)
    end

    # Scoped to the CFD card, because the page legitimately contains the word
    # "Done" elsewhere — this control's own label.
    defp cfd_section(html) do
      [section] = Regex.run(~r/<section[^>]*data-metrics-cumulative-flow\b.*?<\/section>/s, html)
      section
    end

    defp cfd_layer_names(html) do
      ~r/data-metrics-cumulative-flow-layer="(\w+)"/
      |> Regex.scan(html, capture: :all_but_first)
      |> List.flatten()
    end

    defp marker_index(html, regex) do
      [{index, _len} | _] = Regex.run(regex, html, return: :index)
      index
    end

    test "renders the checkbox in the chart group, not the header toolbar", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/metrics")

      assert html =~ "data-metrics-cfd-group"
      assert html =~ "data-metrics-cfd-done-selector"

      # The three data-scope selectors live in the header; this display-only one
      # must not.
      [header] = Regex.run(~r/<header[^>]*data-metrics-header\b.*?<\/header>/s, html)
      refute header =~ "data-metrics-cfd-done-selector"
      refute header =~ "cfd-done-filter-form"

      # Ordering: after the leaderboard, and above the CFD card it controls.
      assert marker_index(html, ~r/data-metrics-agent-leaderboard/) <
               marker_index(html, ~r/data-metrics-cfd-done-selector/)

      assert marker_index(html, ~r/data-metrics-cfd-done-selector/) <
               marker_index(html, ~r/<section[^>]*data-metrics-cumulative-flow\b/)

      assert html =~ ~r/data-metrics-cfd-group[^>]*>\s*<form id="cfd-done-filter-form"/
    end

    test "the box is checked on the connected mount and all five bands render",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/metrics")

      assert cfd_done_checked?(html)
      assert cfd_layer_names(html) == ~w(done review doing ready backlog)
      assert cfd_section(html) =~ "var(--st-done)"
    end

    test "the box is checked on the disconnected static render too", %{conn: conn} do
      # The placeholder path seeds one zero-filled snapshot per day, and the
      # component emits a path for all five bands regardless of magnitude — so
      # "checked" is provable on chart markup here, not just on the input.
      static_html = conn |> get(~p"/metrics") |> html_response(200)

      assert cfd_done_checked?(static_html)
      assert cfd_layer_names(static_html) == ~w(done review doing ready backlog)
    end

    test "unchecking removes the Done band and its legend swatch", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/metrics")

      # An unchecked box omits the key entirely — this is the payload the browser
      # actually sends. Sent to the view directly rather than through element/2,
      # because element-based render_change merges the params with the rendered
      # DOM, which still carries checked="checked" and would mask the omission.
      html = render_change(view, "cfd_done_filter_change", %{})

      refute cfd_done_checked?(html)
      refute html =~ ~s(data-metrics-cumulative-flow-layer="done")
      assert cfd_layer_names(html) == ~w(review doing ready backlog)
      refute cfd_section(html) =~ "var(--st-done)"

      for token <- ~w(--st-backlog --st-ready --st-doing --st-review) do
        assert cfd_section(html) =~ "var(#{token})"
      end
    end

    test "re-checking restores the five-band chart", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/metrics")

      render_change(view, "cfd_done_filter_change", %{})

      html =
        view
        |> element("#cfd-done-filter-form")
        |> render_change(%{"cfd_show_done" => "true"})

      assert cfd_done_checked?(html)
      assert cfd_layer_names(html) == ~w(done review doing ready backlog)
      assert cfd_section(html) =~ "var(--st-done)"
    end

    test "toggling the Done band does not re-read the workspace metrics",
         %{conn: conn, user: user} do
      column = user |> board_fixture() |> column_fixture()

      # Mounted with no completed work: the leaderboard is in its empty state.
      {:ok, view, html} = live(conn, ~p"/metrics")
      assert html =~ "data-metrics-agent-leaderboard-empty"
      refute html =~ "Zeta"

      # Insert completed work AFTER the mount. The LiveView shares this test's
      # sandbox connection, so ANY subsequent read would surface it.
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      completed_at = DateTime.add(now, -3600, :second)
      claimed_at = DateTime.add(completed_at, -3600, :second)
      t = task_fixture(column, %{completed_by_agent: "Zeta"})
      {:ok, _} = Tasks.update_task(t, %{claimed_at: claimed_at, completed_at: completed_at})

      # The toggle assigns only, so the render still shows the pre-insert data.
      html = render_change(view, "cfd_done_filter_change", %{})
      assert cfd_layer_names(html) == ~w(review doing ready backlog)
      assert html =~ "data-metrics-agent-leaderboard-empty"
      refute html =~ "Zeta"

      # Control: a selector that DOES re-read surfaces the row — proving the
      # assertions above are not a false pass on invisible data.
      html = view |> element("#window-days-form") |> render_change(%{"window_days" => "30"})
      assert html =~ "Zeta"
      refute html =~ "data-metrics-agent-leaderboard-empty"
    end

    test "toggling the box issues no database query at all", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/metrics")

      test_pid = self()
      handler_id = "w1956-cfd-toggle-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:kanban, :repo, :query],
        fn _event, _measure, meta, _cfg -> send(test_pid, {:repo_query, meta[:query]}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      render_change(view, "cfd_done_filter_change", %{})

      refute_received {:repo_query, _}
    end

    test "the toggle survives a board-filter change in every shape", %{conn: conn, user: user} do
      board1 = board_fixture(user)
      _board2 = board_fixture(user)

      {:ok, view, _html} = live(conn, ~p"/metrics")

      render_change(view, "cfd_done_filter_change", %{})

      all_ids = user |> Kanban.Boards.list_boards() |> Enum.map(&to_string(&1.id))

      # A strict subset, then all boards.
      for params <- [%{"board_ids" => [to_string(board1.id)]}, %{"board_ids" => all_ids}] do
        html = view |> element("#board-filter-form") |> render_change(params)

        refute cfd_done_checked?(html)
        assert cfd_layer_names(html) == ~w(review doing ready backlog)
      end

      # Then none. Sent to the view directly rather than through element/2:
      # element-based render_change merges the rendered DOM, whose boxes are
      # still checked from the iteration above, so it would never deliver the
      # omitted-key payload a real browser sends when every box is unchecked.
      html = render_change(view, "board_filter_change", %{})

      assert :sys.get_state(view.pid).socket.assigns.selected_board_ids == []
      refute cfd_done_checked?(html)
      assert cfd_layer_names(html) == ~w(review doing ready backlog)
    end

    test "the toggle survives an exclude-weekends change in both directions",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/metrics")

      render_change(view, "cfd_done_filter_change", %{})

      html =
        view |> element("#weekend-filter-form") |> render_change(%{"exclude_weekends" => "true"})

      assert weekend_checked?(html)
      refute cfd_done_checked?(html)
      assert cfd_layer_names(html) == ~w(review doing ready backlog)

      html = render_change(view, "weekend_filter_change", %{})

      refute weekend_checked?(html)
      refute cfd_done_checked?(html)
      assert cfd_layer_names(html) == ~w(review doing ready backlog)
    end

    test "the handler touches exactly one assign and nothing else", %{conn: conn, user: user} do
      _board = board_fixture(user)

      {:ok, view, _html} = live(conn, ~p"/metrics")

      view |> element("#window-days-form") |> render_change(%{"window_days" => "7"})
      view |> element("#weekend-filter-form") |> render_change(%{"exclude_weekends" => "true"})

      before = :sys.get_state(view.pid).socket.assigns
      render_change(view, "cfd_done_filter_change", %{})
      later = :sys.get_state(view.pid).socket.assigns

      # The symmetric difference of the WHOLE assigns map across the toggle must
      # be exactly this one key: no assign is added, none is removed, and no
      # unrelated assign changes to a DIFFERENT value — so the handler cannot
      # quietly reset the window, weekend, or board selection (both of which the
      # setup above deliberately perturbs first).
      #
      # Note what this does NOT prove: comparison is by value, so a handler that
      # called assign_workspace_metrics/2 and got byte-equal series back would
      # still pass here. The no-re-read guarantee is held by the telemetry test
      # above ("issues no database query at all"), which observes the query
      # attempt rather than its result — do not delete it as redundant.
      diff =
        before
        |> Map.merge(later, fn _k, a, b -> if a == b, do: :__same__, else: {a, b} end)
        |> Enum.reject(fn {_k, v} -> v == :__same__ end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.reject(&(&1 == :__changed__))

      assert diff == [:cfd_show_done]
    end

    test "the toggle survives a selector change that DOES re-read", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/metrics")

      render_change(view, "cfd_done_filter_change", %{})

      html = view |> element("#window-days-form") |> render_change(%{"window_days" => "30"})

      # put_overview/3 must not clobber the display-only assign.
      refute cfd_done_checked?(html)
      assert cfd_layer_names(html) == ~w(review doing ready backlog)
      assert throughput_points(html) == 30
    end

    test "a fresh mount resets the box to checked (session-only)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/metrics")

      render_change(view, "cfd_done_filter_change", %{})

      {:ok, _view2, html2} = live(conn, ~p"/metrics")

      assert cfd_done_checked?(html2)
      assert cfd_layer_names(html2) == ~w(done review doing ready backlog)
    end

    test "a hostile param value resolves to false and never reaches the markup",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/metrics")

      html =
        render_change(view, "cfd_done_filter_change", %{
          "cfd_show_done" => "\"><script>alert(1)</script>"
        })

      assert :sys.get_state(view.pid).socket.assigns.cfd_show_done == false
      refute html =~ "alert(1)"
      assert cfd_layer_names(html) == ~w(review doing ready backlog)
    end

    test "the control uses only theme tokens so it reads in light and dark mode",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/metrics")

      [form] = Regex.run(~r/<form id="cfd-done-filter-form".*?<\/form>/s, html)

      for token <- ~w(--surface --line --ink-2 --stride-orange) do
        assert form =~ "var(#{token})"
      end

      refute form =~ ~r/#[0-9a-fA-F]{3,6}\b/
      refute form =~ "text-gray-"
      refute form =~ "bg-white"
    end

    test "the checkbox label renders through gettext/1", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/metrics")

      assert html =~ "Show Done"
    end

    test "the label is actually translated, not hardcoded English", %{conn: conn} do
      # The LiveView runs in its own process, so put_locale/2 in the test process
      # would not reach it — KanbanWeb.LocaleOnMount reads session["locale"].
      {:ok, _view, html} =
        conn
        |> Plug.Test.init_test_session(%{"locale" => "fr"})
        |> live(~p"/metrics")

      [form] = Regex.run(~r/<form id="cfd-done-filter-form".*?<\/form>/s, html)

      assert form =~ "Afficher Terminé"
      refute form =~ "Show Done"
    end
  end

  # A completed task whose claimed-to-completed span is `minutes`, landing on
  describe "export dropdown" do
    setup [:register_and_log_in_user]

    # Both export hrefs in render order: the PDF link first, then the Excel
    # link, which differs only by the `format` parameter.
    defp export_hrefs(html) do
      ~r/href="(\/metrics\/export\?[^"]+)"/
      |> Regex.scan(html, capture: :all_but_first)
      |> List.flatten()
    end

    test "renders the dropdown in the page header offering PDF and Excel", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/metrics")

      assert html =~ "workspace-export-dropdown"
      assert [pdf, excel] = export_hrefs(html)
      refute pdf =~ "format=excel"
      assert excel =~ "format=excel"
    end

    test "both links carry the current window and the browser timezone", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/metrics")

      for href <- export_hrefs(html) do
        assert href =~ "window_days=14"
        # Without a tz connect param the page falls back to Etc/UTC; the link
        # must still carry it, or the export buckets days in UTC by accident
        # rather than by agreement with the page.
        assert href =~ "timezone=Etc%2FUTC"
      end
    end

    test "changing the window selector updates both links", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/metrics")

      html =
        view
        |> element("#window-days-form")
        |> render_change(%{"window_days" => "30"})

      assert [_pdf, _excel] = hrefs = export_hrefs(html)

      for href <- hrefs do
        assert href =~ "window_days=30"
        refute href =~ "window_days=14"
      end
    end

    test "changing the board selector updates both links", %{conn: conn, user: user} do
      board = board_fixture(user, %{name: "Alpha Board"})
      other = board_fixture(user, %{name: "Beta Board"})

      {:ok, view, html} = live(conn, ~p"/metrics")

      # The page mounts with EVERY board selected, which it treats as "all
      # visible boards" — so the links carry no subset at all, matching the
      # scope the page itself queries with.
      for href <- export_hrefs(html), do: refute(href =~ "board_ids")

      updated =
        view
        |> element("#board-filter-form")
        |> render_change(%{"board_ids" => [to_string(board.id)]})

      # Narrowing to a real subset puts it on both links.
      for href <- export_hrefs(updated) do
        assert href =~ "board_ids%5B%5D=#{board.id}"
        refute href =~ "board_ids%5B%5D=#{other.id}"
      end
    end

    test "the links carry no subset when the selection is cleared", %{conn: conn, user: user} do
      _board = board_fixture(user, %{name: "Alpha Board"})

      {:ok, view, _html} = live(conn, ~p"/metrics")

      # Deselecting everything also means "all visible boards" on the page,
      # which the export route reads from the ABSENCE of the parameter.
      cleared = render_change(view, "board_filter_change", %{})

      for href <- export_hrefs(cleared), do: refute(href =~ "board_ids")
    end

    test "re-selecting every board drops the subset again, matching the page's own scope",
         %{conn: conn, user: user} do
      board = board_fixture(user, %{name: "Alpha Board"})
      other = board_fixture(user, %{name: "Beta Board"})

      {:ok, view, _html} = live(conn, ~p"/metrics")

      narrowed =
        view
        |> element("#board-filter-form")
        |> render_change(%{"board_ids" => [to_string(board.id)]})

      for href <- export_hrefs(narrowed), do: assert(href =~ "board_ids")

      widened =
        view
        |> element("#board-filter-form")
        |> render_change(%{"board_ids" => [to_string(board.id), to_string(other.id)]})

      # An all-selected state is "all boards" on screen; the export must say the
      # same thing rather than pinning today's ids.
      for href <- export_hrefs(widened), do: refute(href =~ "board_ids")
    end

    test "changing the weekend filter updates both links", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/metrics")

      for href <- export_hrefs(html), do: assert(href =~ "exclude_weekends=false")

      updated =
        view
        |> element("#weekend-filter-form")
        |> render_change(%{"exclude_weekends" => "true"})

      for href <- export_hrefs(updated), do: assert(href =~ "exclude_weekends=true")
    end
  end

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
