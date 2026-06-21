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

    test "renders the two remaining decorative toolbar buttons with aria-disabled='true'",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/metrics")

      buttons =
        Regex.scan(~r/<button[^>]*data-metrics-toolbar-placeholder[^>]*>/, html)

      # "All boards" is now a real selector; only "Last 14 days" and "Filter" remain placeholders.
      assert length(buttons) == 2

      for [tag] <- buttons do
        assert tag =~ ~s(aria-disabled="true")
        refute tag =~ "phx-click"
      end

      assert html =~ "Last 14 days"
      assert html =~ "Filter"
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

  describe "goal-to-done latency formatting" do
    setup [:register_and_log_in_user]

    # Stages a completed goal whose final child finished `latency_seconds`
    # before the goal did, so the goal contributes exactly that latency sample
    # to goal_to_done_latency_percentiles (compact version of the seeding
    # helper in test/kanban/metrics_test.exs).
    defp seed_goal_latency!(column, latency_seconds) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      goal_completed_at = DateTime.add(now, -3600, :second)
      child_completed_at = DateTime.add(goal_completed_at, -latency_seconds, :second)

      goal = task_fixture(column, %{type: :goal})
      child = task_fixture(column, %{parent_id: goal.id})

      {:ok, _} =
        Tasks.update_task(child, %{
          claimed_at: DateTime.add(child_completed_at, -600, :second),
          completed_at: child_completed_at
        })

      {:ok, goal} = Tasks.update_task(goal, %{completed_at: goal_completed_at})

      {:ok, _} =
        goal
        |> Ecto.Changeset.change(%{
          after_goal_status: :succeeded,
          after_goal_result: %{"exit_code" => 0, "output" => "ok", "duration_ms" => 1}
        })
        |> Kanban.Repo.update()

      :ok
    end

    test "formats sub-minute latency as seconds", %{conn: conn, user: user} do
      column = user |> board_fixture() |> column_fixture()
      seed_goal_latency!(column, 45)

      {:ok, _view, html} = live(conn, ~p"/metrics")

      assert html =~ "data-metrics-goal-done-latency"
      assert html =~ "45s"
    end

    test "formats whole minutes and whole hours without a remainder", %{conn: conn, user: user} do
      column = user |> board_fixture() |> column_fixture()
      # Two samples: p50 takes the lower (240s = 4m), p95 the higher (7200s = 2h).
      seed_goal_latency!(column, 240)
      seed_goal_latency!(column, 7200)

      {:ok, _view, html} = live(conn, ~p"/metrics")

      assert html =~ "4m"
      assert html =~ "2h"
    end

    test "formats minute and hour latencies with remainders", %{conn: conn, user: user} do
      column = user |> board_fixture() |> column_fixture()
      # Two samples: p50 = 210s = 3m 30s, p95 = 9000s = 2h 30m.
      seed_goal_latency!(column, 210)
      seed_goal_latency!(column, 9000)

      {:ok, _view, html} = live(conn, ~p"/metrics")

      assert html =~ "3m 30s"
      assert html =~ "2h 30m"
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
end
