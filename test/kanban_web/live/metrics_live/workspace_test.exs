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

    test "renders the decorative toolbar buttons with aria-disabled='true' and no phx-click",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/metrics")

      buttons =
        Regex.scan(~r/<button[^>]*data-metrics-toolbar-placeholder[^>]*>/, html)

      assert length(buttons) == 3

      for [tag] <- buttons do
        assert tag =~ ~s(aria-disabled="true")
        refute tag =~ "phx-click"
      end

      assert html =~ "All boards"
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
end
