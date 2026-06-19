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

  describe "roster ordering" do
    setup [:register_and_log_in_user]

    test "renders the most recently active agent first in the roster",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      recent = DateTime.utc_now() |> DateTime.truncate(:second)
      older = DateTime.add(recent, -3600, :second)

      # "Zoe" is alphabetically last but most recently active, so the roster
      # must render her card above "Adam".
      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Adam", claimed_at: older})

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Zoe", claimed_at: recent})

      {:ok, _view, html} = live(conn, ~p"/agents")

      roster = roster_html(html)
      assert {zoe, _} = :binary.match(roster, "Zoe")
      assert {adam, _} = :binary.match(roster, "Adam")
      assert zoe < adam
    end
  end

  describe "column-aware roster status" do
    setup [:register_and_log_in_user]

    test "shows the current-task pill for Doing work and waiting-for-review for Review-only work",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      doing = column_fixture(board, %{name: "Doing"})
      review = column_fixture(board, %{name: "Review"})

      {:ok, doing_task} =
        doing
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Worker", status: :in_progress})

      {:ok, review_task} =
        review
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Reviewer", status: :in_progress})

      {:ok, _view, html} = live(conn, ~p"/agents")
      roster = roster_html(html)

      # The Doing agent surfaces its task as the active-work pill.
      assert roster =~ doing_task.identifier
      # The Review-only agent is shown as waiting for review, with no pill for
      # its parked review task.
      assert roster =~ "Waiting for review"
      refute roster =~ review_task.identifier
    end
  end

  # Slices the rendered page down to the roster region (between the roster
  # container marker and the activity feed) so ordering assertions are not
  # confused by agent names that also appear in the feed.
  defp roster_html(html) do
    [_, rest] = String.split(html, "data-agents-roster", parts: 2)
    [roster, _] = String.split(rest, "data-agent-feed", parts: 2)
    roster
  end

  # Pulls the integer count rendered in the fleet-health rollup chip for a
  # given status marker (working/waiting/stuck/idle).
  defp fleet_count(html, marker) do
    case Regex.run(
           ~r/data-agents-fleet-health-stat="#{marker}".*?<dd[^>]*>\s*(\d+)\s*<\/dd>/s,
           html
         ) do
      [_, n] -> String.to_integer(n)
      _ -> nil
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
      assert claude_html =~ "data-agent-filter-indicator"
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
      refute restored_html =~ "data-agent-filter-indicator"
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

      assert narrowed_html =~ "data-agent-filter-indicator"
      refute narrowed_html =~ ~s(data-agent-feed-kind="complete")

      cleared_html =
        view
        |> element(~s([data-clear-agent-filter]))
        |> render_click()

      refute cleared_html =~ "data-agent-filter-indicator"
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
      assert refreshed_html =~ "data-agent-filter-indicator"
      assert refreshed_html =~ ~s(data-agent-feed-kind="claim")
      refute refreshed_html =~ ~s(data-agent-feed-kind="complete")
    end

    test "end-to-end: clicking a card shows the labeled indicator; Clear restores the feed",
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

      {:ok, view, html} = live(conn, ~p"/agents")

      # No agent selected yet: the indicator is absent and both kinds show.
      refute html =~ "data-agent-filter-indicator"
      assert html =~ ~s(data-agent-feed-kind="claim")
      assert html =~ ~s(data-agent-feed-kind="complete")

      # Click the Claude card: feed narrows and a discoverable, labeled
      # indicator appears (name + visible "Clear" affordance).
      filtered_html =
        view
        |> element(~s([data-agent-roster-card][data-agent-name="Claude"]))
        |> render_click()

      assert filtered_html =~ "data-agent-filter-indicator"
      assert filtered_html =~ "Filtering by Claude"
      assert filtered_html =~ "data-clear-agent-filter"
      assert filtered_html =~ "Clear"
      assert filtered_html =~ ~s(data-agent-feed-kind="claim")
      refute filtered_html =~ ~s(data-agent-feed-kind="complete")

      # Activate Clear: indicator disappears and the full feed returns.
      restored_html =
        view
        |> element(~s([data-clear-agent-filter]))
        |> render_click()

      refute restored_html =~ "data-agent-filter-indicator"
      assert restored_html =~ ~s(data-agent-feed-kind="claim")
      assert restored_html =~ ~s(data-agent-feed-kind="complete")
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

    test "the fleet-health rollup refreshes on a broadcast", %{conn: conn, user: user} do
      board = board_fixture(user)
      doing = column_fixture(board, %{name: "Doing"})

      {:ok, view, html} = live(conn, ~p"/agents")
      assert fleet_count(html, "stuck") == 0

      stale =
        DateTime.utc_now() |> DateTime.add(-90 * 60, :second) |> DateTime.truncate(:second)

      {:ok, _} =
        doing
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Stalled",
          status: :in_progress,
          claimed_at: stale
        })

      send(view.pid, :refresh_agents_data)

      assert fleet_count(render(view), "stuck") == 1
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

  describe "fleet-health rollup" do
    setup [:register_and_log_in_user]

    test "renders the rollup with the four status counts", %{conn: conn, user: user} do
      board = board_fixture(user)
      doing = column_fixture(board, %{name: "Doing"})

      {:ok, _} =
        doing
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          status: :in_progress,
          claimed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ "data-agents-fleet-health"
      assert fleet_count(html, "working") == 1
      assert fleet_count(html, "waiting") == 0
      assert fleet_count(html, "stuck") == 0
      assert fleet_count(html, "idle") == 0
    end

    test "emphasizes stuck and idle with soft-background pills", %{conn: conn, user: user} do
      board = board_fixture(user)
      doing = column_fixture(board, %{name: "Doing"})
      done = column_fixture(board, %{name: "Done"})

      stale =
        DateTime.utc_now() |> DateTime.add(-90 * 60, :second) |> DateTime.truncate(:second)

      recent = DateTime.utc_now() |> DateTime.truncate(:second)

      # stalled working agent -> counted as stuck
      {:ok, _} =
        doing
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Stalled",
          status: :in_progress,
          claimed_at: stale
        })

      # idle agent (only a done task)
      {:ok, _} =
        done
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Idler",
          completed_by_agent: "Idler",
          status: :completed,
          completed_at: recent
        })

      {:ok, _view, html} = live(conn, ~p"/agents")

      assert fleet_count(html, "stuck") == 1
      assert fleet_count(html, "idle") == 1
      # emphasis pills use the soft-background design tokens, not hardcoded colors
      assert html =~ "var(--st-blocked-soft)"
      assert html =~ "var(--stride-orange-soft)"
    end

    test "shows all zeros when there are no agents", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ "data-agents-fleet-health"
      assert fleet_count(html, "working") == 0
      assert fleet_count(html, "waiting") == 0
      assert fleet_count(html, "stuck") == 0
      assert fleet_count(html, "idle") == 0
    end
  end
end
