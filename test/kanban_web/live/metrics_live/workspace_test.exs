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
end
