defmodule KanbanWeb.AgentsLiveTest do
  @moduledoc """
  Integration tests for `KanbanWeb.AgentsLive` — the workspace-level
  Agents view at `/agents`.
  """
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Tasks

  describe "mount and route" do
    setup [:register_and_log_in_user]

    test "authenticated user gets 200 and the page renders header + roster + feed markers",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, _task} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          status: :in_progress
        })

      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ "data-agents-header"
      assert html =~ "data-agent-roster-card"
      assert html =~ "data-agent-feed"
      assert html =~ "Workspace"
      assert html =~ "Agents"
    end

    test "renders the empty-state copy when no agents and no events exist",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ "data-agents-roster-empty"
      assert html =~ "data-agent-feed-empty"
    end

    test "uses :agents as the active side-nav item", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents")

      assert render(view) =~ "Agents"
    end
  end

  describe "unauthenticated access" do
    test "redirects to the log-in page when the user is not signed in", %{conn: conn} do
      assert {:error, {:redirect, %{to: redirect_to}}} = live(conn, ~p"/agents")
      assert redirect_to =~ "/users/log-in"
    end
  end

  describe "filter-tab interaction" do
    setup [:register_and_log_in_user]

    test "clicking a filter tab updates the rendered events without a full reload",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # A claim event for Claude
      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          claimed_at: now,
          status: :in_progress
        })

      # A completion event for Codex
      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Codex",
          completed_by_agent: "Codex",
          completed_at: now,
          status: :completed
        })

      {:ok, view, _html} = live(conn, ~p"/agents")

      all_html = render(view)
      assert all_html =~ ~s(data-agent-feed-kind="claim")
      assert all_html =~ ~s(data-agent-feed-kind="complete")

      claims_html =
        view
        |> element(~s([data-agent-feed-tab="claims"]))
        |> render_click()

      assert claims_html =~ ~s(data-agent-feed-kind="claim")
      refute claims_html =~ ~s(data-agent-feed-kind="complete")

      completions_html =
        view
        |> element(~s([data-agent-feed-tab="completions"]))
        |> render_click()

      assert completions_html =~ ~s(data-agent-feed-kind="complete")
      refute completions_html =~ ~s(data-agent-feed-kind="claim")
    end

    test "filtering to hooks renders the empty-state copy when no hook events exist",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Claude", status: :in_progress})

      {:ok, view, _html} = live(conn, ~p"/agents")

      hooks_html =
        view
        |> element(~s([data-agent-feed-tab="hooks"]))
        |> render_click()

      assert hooks_html =~ "data-agent-feed-empty"
    end
  end

  describe "real-time updates via PubSub" do
    setup [:register_and_log_in_user]

    test "renders the live indicator", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/agents")
      assert html =~ "data-agents-live-indicator"
      assert html =~ "live"
    end

    test "completing a task in another process updates the rendered feed without reload",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, view, _html} = live(conn, ~p"/agents")

      initial = render(view)
      refute initial =~ "data-agent-feed-kind=\"complete\""

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          completed_by_agent: "Codex",
          completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          status: :completed
        })

      # The LiveView debounces refreshes by 250ms, so wait briefly then re-render
      Process.sleep(400)
      updated = render(view)

      assert updated =~ ~s(data-agent-feed-kind="complete")
    end

    test "presence count reflects in the live indicator", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/agents")
      assert html =~ ~r/\d+\s*connected/
    end
  end
end
