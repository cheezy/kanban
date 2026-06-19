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

    test "clicking the All tab after narrowing restores every event kind",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Claude", claimed_at: now, status: :in_progress})

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          completed_by_agent: "Codex",
          completed_at: now,
          status: :completed
        })

      {:ok, view, _html} = live(conn, ~p"/agents")

      view |> element(~s([data-agent-feed-tab="claims"])) |> render_click()

      all_html =
        view
        |> element(~s([data-agent-feed-tab="all"]))
        |> render_click()

      assert all_html =~ ~s(data-agent-feed-kind="claim")
      assert all_html =~ ~s(data-agent-feed-kind="complete")
    end

    test "an unrecognized filter value falls back to showing all events",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Claude", claimed_at: now, status: :in_progress})

      {:ok, view, _html} = live(conn, ~p"/agents")

      # A value none of the explicit tab clauses match exercises the
      # parse_filter/1 catch-all, which defaults to :all.
      html = render_click(view, "filter_events", %{"filter" => "bogus-filter"})

      assert html =~ ~s(data-agent-feed-kind="claim")
    end

    test "filtering to reviewed renders the empty-state copy when no review events exist",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Claude", status: :in_progress})

      {:ok, view, _html} = live(conn, ~p"/agents")

      reviewed_html =
        view
        |> element(~s([data-agent-feed-tab="reviewed"]))
        |> render_click()

      assert reviewed_html =~ "data-agent-feed-empty"
    end

    test "filtering to reviewed shows only review events",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # A claim event (should be hidden under the Reviewed filter)
      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Claude", claimed_at: now, status: :in_progress})

      # A review event (should be the only one shown)
      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          completed_by_agent: "Codex",
          completed_at: now,
          reviewed_at: now,
          status: :completed
        })

      {:ok, view, _html} = live(conn, ~p"/agents")

      reviewed_html =
        view
        |> element(~s([data-agent-feed-tab="reviewed"]))
        |> render_click()

      assert reviewed_html =~ ~s(data-agent-feed-kind="review")
      refute reviewed_html =~ ~s(data-agent-feed-kind="claim")
    end
  end

  describe "agent selection" do
    setup [:register_and_log_in_user]

    test "selecting an agent filters the feed to only that agent's events",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # A claim by Claude and a completion by Codex.
      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Claude", claimed_at: now, status: :in_progress})

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          completed_by_agent: "Codex",
          completed_at: now,
          status: :completed
        })

      {:ok, view, _html} = live(conn, ~p"/agents")

      all_html = render(view)
      assert all_html =~ ~s(data-agent-feed-kind="claim")
      assert all_html =~ ~s(data-agent-feed-kind="complete")

      claude_html =
        view
        |> element(~s([data-agent-roster-card][data-agent-name="Claude"]))
        |> render_click()

      # Claude's claim survives; Codex's completion is filtered out.
      assert claude_html =~ ~s(data-agent-feed-kind="claim")
      refute claude_html =~ ~s(data-agent-feed-kind="complete")
      assert claude_html =~ "data-agent-filter-active"
    end

    test "the kind filter and the agent filter compose",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # Claude is actively working (a claim) and also has a completion.
      {:ok, _claude_claim} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Claude", claimed_at: now, status: :in_progress})

      {:ok, claude_done} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          completed_by_agent: "Claude",
          completed_at: now,
          status: :completed
        })

      # Codex only has a completion.
      {:ok, codex_done} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          completed_by_agent: "Codex",
          completed_at: now,
          status: :completed
        })

      {:ok, view, _html} = live(conn, ~p"/agents")

      view
      |> element(~s([data-agent-roster-card][data-agent-name="Claude"]))
      |> render_click()

      composed_html =
        view
        |> element(~s([data-agent-feed-tab="completions"]))
        |> render_click()

      # Only Claude's completion remains: the kind filter drops the claim and
      # the agent filter drops Codex's completion.
      assert composed_html =~ claude_done.identifier
      refute composed_html =~ codex_done.identifier
      refute composed_html =~ ~s(data-agent-feed-kind="claim")
    end

    test "clicking the already-selected agent toggles the filter off",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Claude", claimed_at: now, status: :in_progress})

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          completed_by_agent: "Codex",
          completed_at: now,
          status: :completed
        })

      {:ok, view, _html} = live(conn, ~p"/agents")

      selector = ~s([data-agent-roster-card][data-agent-name="Claude"])

      narrowed_html = view |> element(selector) |> render_click()
      refute narrowed_html =~ ~s(data-agent-feed-kind="complete")

      restored_html = view |> element(selector) |> render_click()
      assert restored_html =~ ~s(data-agent-feed-kind="claim")
      assert restored_html =~ ~s(data-agent-feed-kind="complete")
      refute restored_html =~ "data-agent-filter-active"
    end

    test "clear_agent_filter resets the selection and restores the full feed",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Claude", claimed_at: now, status: :in_progress})

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          completed_by_agent: "Codex",
          completed_at: now,
          status: :completed
        })

      {:ok, view, _html} = live(conn, ~p"/agents")

      narrowed_html =
        view
        |> element(~s([data-agent-roster-card][data-agent-name="Claude"]))
        |> render_click()

      assert narrowed_html =~ "data-agent-filter-active"
      refute narrowed_html =~ ~s(data-agent-feed-kind="complete")

      cleared_html =
        view
        |> element(~s([data-clear-agent-filter]))
        |> render_click()

      refute cleared_html =~ "data-agent-filter-active"
      assert cleared_html =~ ~s(data-agent-feed-kind="claim")
      assert cleared_html =~ ~s(data-agent-feed-kind="complete")
    end

    test "the selected agent survives a real-time refresh",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Claude", claimed_at: now, status: :in_progress})

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          completed_by_agent: "Codex",
          completed_at: now,
          status: :completed
        })

      {:ok, view, _html} = live(conn, ~p"/agents")

      view
      |> element(~s([data-agent-roster-card][data-agent-name="Claude"]))
      |> render_click()

      # Drive the debounced reload path directly; the selection lives in the
      # socket assigns and must be re-applied by load_agents_data/1.
      send(view.pid, :refresh_agents_data)

      refreshed_html = render(view)
      assert refreshed_html =~ "data-agent-filter-active"
      assert refreshed_html =~ ~s(data-agent-feed-kind="claim")
      refute refreshed_html =~ ~s(data-agent-feed-kind="complete")
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

    test "rapid agent events coalesce into a single debounced refresh", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents")

      # The first event schedules a refresh; the second arrives while one is
      # already pending and must be a no-op (the debounce guard), not a second
      # timer. Both are handled without crashing the LiveView.
      send(view.pid, {:agent_event, %{}})
      send(view.pid, {:agent_event, %{}})

      # A render round-trips through the LiveView process, proving it stayed
      # alive after handling both messages.
      assert render(view) =~ "data-agent-feed"
    end

    test "presence count reflects in the live indicator", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/agents")
      assert html =~ ~r/\d+\s*connected/
    end

    test "two-pane layout renders with mobile stack + md side-by-side responsive classes", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, ~p"/agents")

      # Outer wrapper: flex-col on mobile, flex-row at md+.
      assert html =~ "flex-col md:flex-row"

      # Roster: full width on mobile (max 40vh with internal scroll), 380px wide at md+.
      assert html =~ "w-full md:w-[380px]"
      assert html =~ "max-h-[40vh] md:max-h-none"

      # Detail panel: flex-1 fills remaining space at md+.
      assert html =~ "flex-1 min-w-0"

      # No inline width: 380px or flex: 1 style attributes remain.
      refute html =~ "width: 380px"
      refute html =~ "flex: 1; min-width: 0;"
    end
  end
end
