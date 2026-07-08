defmodule KanbanWeb.AgentsLiveTest do
  @moduledoc """
  Integration tests for `KanbanWeb.AgentsLive` — the workspace-level
  Agents view at `/agents`.
  """
  use KanbanWeb.ConnCase

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TargetsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Boards
  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.AgentWorkflow

  describe "board and time-range filter" do
    setup [:register_and_log_in_user]

    defp agent_on(column, name) do
      {:ok, _} = column |> task_fixture() |> Tasks.update_task(%{created_by_agent: name})
      :ok
    end

    test "renders the board selector and the time-range selector", %{conn: conn, user: user} do
      board = board_fixture(user)
      board |> column_fixture() |> agent_on("Claude")

      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ ~s(id="agents-filter-form")
      assert html =~ ~s(name="board_id")
      assert html =~ ~s(name="time_range")
      assert html =~ "All Boards"
      assert html =~ "All Time"
      assert html =~ board.name

      # W1383: the filters now live in the header (top-right), not in a separate
      # band below the PM-trends section. Lock the placement by asserting the form
      # renders inside the header element and ahead of the PM-trends section.
      assert html =~ "data-agents-header"

      header_pos = :binary.match(html, "data-agents-header") |> elem(0)
      form_pos = :binary.match(html, ~s(id="agents-filter-form")) |> elem(0)
      pm_trends_pos = :binary.match(html, "data-agents-pm-trends") |> elem(0)
      assert header_pos < form_pos and form_pos < pm_trends_pos
    end

    test "selecting a board narrows the roster to that board's agents",
         %{conn: conn, user: user} do
      board_a = board_fixture(user)
      board_a |> column_fixture() |> agent_on("Alpha")
      board_b = board_fixture(user)
      board_b |> column_fixture() |> agent_on("Bravo")

      {:ok, view, html} = live(conn, ~p"/agents")
      assert html =~ "Alpha"
      assert html =~ "Bravo"

      filtered =
        view |> form("#agents-filter-form", %{"board_id" => board_a.id}) |> render_change()

      assert filtered =~ "Alpha"
      refute filtered =~ "Bravo"

      # Selecting "All Boards" (value "") restores the full cross-board view.
      restored = view |> form("#agents-filter-form", %{"board_id" => ""}) |> render_change()
      assert restored =~ "Alpha"
      assert restored =~ "Bravo"
    end

    test "selecting a narrow time window drops activity outside it",
         %{conn: conn, user: user} do
      column = user |> board_fixture() |> column_fixture()
      agent_on(column, "Recent")
      {:ok, stale} = column |> task_fixture() |> Tasks.update_task(%{created_by_agent: "Stale"})
      backdate_updated_at(stale, ~N[2020-01-01 00:00:00])

      {:ok, view, html} = live(conn, ~p"/agents")
      assert html =~ "Recent"
      assert html =~ "Stale"

      filtered =
        view |> form("#agents-filter-form", %{"time_range" => "last_7_days"}) |> render_change()

      assert filtered =~ "Recent"
      refute filtered =~ "Stale"

      # "All Time" restores the unbounded view.
      restored =
        view |> form("#agents-filter-form", %{"time_range" => "all_time"}) |> render_change()

      assert restored =~ "Recent"
      assert restored =~ "Stale"
    end

    test "board and days selectors compose", %{conn: conn, user: user} do
      board_a = board_fixture(user)
      col_a = column_fixture(board_a)
      agent_on(col_a, "InWindow")
      {:ok, old} = col_a |> task_fixture() |> Tasks.update_task(%{created_by_agent: "OldOnA"})
      backdate_updated_at(old, ~N[2020-01-01 00:00:00])
      board_b = board_fixture(user)
      board_b |> column_fixture() |> agent_on("OnBoardB")

      {:ok, view, _html} = live(conn, ~p"/agents")

      filtered =
        view
        |> form("#agents-filter-form", %{"board_id" => board_a.id, "time_range" => "last_7_days"})
        |> render_change()

      assert filtered =~ "InWindow"
      refute filtered =~ "OldOnA"
      refute filtered =~ "OnBoardB"
    end

    defp backdate_updated_at(%{id: id}, at) do
      from(t in Tasks.Task, where: t.id == ^id)
      |> Repo.update_all(set: [updated_at: at])
    end
  end

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

  # Pulls the rendered value (count, percent, or cycle-time string) from a
  # PM-trends stat card for a given marker (throughput-today, success-rate, …).
  defp pm_trends_value(html, marker) do
    case Regex.run(
           ~r/data-agents-pm-trends-stat="#{marker}".*?<dd[^>]*>\s*(.*?)\s*<\/dd>/s,
           html
         ) do
      [_, v] -> v
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

      view
      |> element(~s([data-agent-feed-tab="completions"]))
      |> render_click()

      # Only Claude's completion remains: the kind filter drops the claim and
      # the agent filter drops Codex's completion. Scope the identifier checks to
      # the feed — short identifiers collide with random substrings in the full
      # page (CSRF token, data-URIs), making a whole-page match flaky.
      composed_html = view |> element(~s([data-agent-feed])) |> render()
      assert composed_html =~ claude_done.identifier
      refute composed_html =~ codex_done.identifier
      refute composed_html =~ ~s(data-agent-feed-kind="claim")
    end

    test "same-named agents under different humans are separate, independently selectable rows (W1244)",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      alice = user_fixture(%{email: "alice-w1244@example.com"})
      bob = user_fixture(%{email: "bob-w1244@example.com"})

      {:ok, alice_done} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          completed_by_agent: "Claude",
          completed_by_id: alice.id,
          completed_at: now,
          status: :completed
        })

      {:ok, bob_done} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          completed_by_agent: "Claude",
          completed_by_id: bob.id,
          completed_at: now,
          status: :completed
        })

      {:ok, view, html} = live(conn, ~p"/agents")

      # Two distinct "Claude" rows, keyed by their human owner.
      assert html =~ ~s(data-agent-name="Claude")
      assert html =~ ~s(data-agent-key="#{alice.id}")
      assert html =~ ~s(data-agent-key="#{bob.id}")

      # Selecting Alice's Claude filters the feed to only her completion.
      alice_html =
        view
        |> element(~s([data-agent-roster-card][data-agent-key="#{alice.id}"]))
        |> render_click()

      assert alice_html =~ "data-agent-filter-indicator"
      assert alice_html =~ ~s(data-selected-agent="Claude")

      # Scope the identifier assertions to the feed section. Short identifiers
      # (e.g. "W2") collide with random substrings elsewhere in the full page
      # (CSRF token, SVG data-URIs, generated ids), making a whole-page match
      # flaky; the feed is where the filtered events actually render.
      feed_html = view |> element(~s([data-agent-feed])) |> render()
      assert feed_html =~ alice_done.identifier
      refute feed_html =~ bob_done.identifier
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

    test "completing via the real complete_task path updates the feed without reload (D86)",
         %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)
      columns = Kanban.Columns.list_columns(board)
      ready = Enum.find(columns, &(&1.name == "Ready"))

      {:ok, task} =
        Tasks.create_task(ready, %{
          "title" => "Live completion task",
          "status" => "open",
          "human_task" => false,
          "created_by_id" => user.id,
          "needs_review" => false
        })

      {:ok, claimed, _hook} =
        AgentWorkflow.claim_next_task([], user, board.id, task.identifier, "Codex")

      {:ok, view, _html} = live(conn, ~p"/agents")
      refute render(view) =~ ~s(data-agent-feed-kind="complete")

      {:ok, _final, _hooks} =
        AgentWorkflow.complete_task(
          claimed,
          user,
          %{
            "completion_summary" => "Did the work",
            "actual_complexity" => "small",
            "actual_files_changed" => "lib/foo.ex",
            "time_spent_minutes" => 30
          },
          "Codex"
        )

      # The LiveView debounces refreshes by 250ms, so wait briefly then re-render.
      Process.sleep(400)

      assert render(view) =~ ~s(data-agent-feed-kind="complete")
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

      # Roster: full width on mobile (flows + scrolls with the page), independent
      # scroll restored only at md+ (no mobile max-height clamp).
      assert html =~ "w-full md:w-[380px]"
      assert html =~ "md:flex-shrink-0 md:overflow-y-auto"
      refute html =~ "max-h-[40vh]"

      # Detail panel: flex-1 fills remaining space at md+.
      assert html =~ "flex-1 min-w-0"

      # No inline width: 380px or flex: 1 style attributes remain.
      refute html =~ "width: 380px"
      refute html =~ "flex: 1; min-width: 0;"
    end

    test "mobile scroll: outer wrapper has no height:100% lock and re-locks at md+", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, ~p"/agents")

      # The /agents content must not clamp itself to viewport height on mobile,
      # so <main> (the one true scroll container) can scroll the whole page.
      refute html =~ "height: 100%; min-height: 0;"
      # Height is re-locked only at md+ so the desktop two-pane split is unchanged.
      assert html =~ "stride-screen md:h-full"
    end

    test "mobile scroll: roster and feed own-scroll only at md+", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/agents")

      # Roster scrolls with the page on mobile; independent scroll only at md+.
      assert html =~ "md:flex-shrink-0 md:overflow-y-auto"
      # Activity feed list scrolls with the page on mobile; own-scroll only at md+.
      assert html =~ "md:overflow-y-auto"
      # The unconditional mobile scroll traps are gone.
      refute html =~ "max-h-[40vh]"
    end

    test "desktop two-pane classes still present", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ "md:flex-row"
      assert html =~ "md:w-[380px]"
      assert html =~ "flex-1 min-w-0"
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

    test "renders working/waiting/idle as a partition and stuck as a separated overlay",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      doing = column_fixture(board, %{name: "Doing"})
      review = column_fixture(board, %{name: "Review"})
      recent = DateTime.utc_now() |> DateTime.truncate(:second)
      stale = DateTime.utc_now() |> DateTime.add(-90 * 60, :second) |> DateTime.truncate(:second)

      # Working agent (not stuck).
      {:ok, _} =
        doing
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Worker",
          status: :in_progress,
          claimed_at: recent
        })

      # Waiting agent that is also stuck (parked in review past the threshold).
      {:ok, _} =
        review
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Reviewer",
          completed_by_agent: "Reviewer",
          status: :in_progress,
          completed_at: stale
        })

      {:ok, _view, html} = live(conn, ~p"/agents")

      # The partition, divider, and overlay structure is present.
      assert html =~ "data-agents-fleet-health-partition"
      assert html =~ "data-agents-fleet-health-divider"
      assert html =~ "data-agents-fleet-health-overlay"
      assert html =~ "of which"

      # working + waiting + idle partition the 2 live agents; stuck (1) overlaps
      # one of them rather than adding a fourth bucket.
      assert fleet_count(html, "working") + fleet_count(html, "waiting") +
               fleet_count(html, "idle") == 2

      assert fleet_count(html, "stuck") == 1

      # Stuck renders inside the overlay (after the partition), not among the
      # partition chips.
      {working_pos, _} = :binary.match(html, ~s(data-agents-fleet-health-stat="working"))
      {overlay_pos, _} = :binary.match(html, "data-agents-fleet-health-overlay")
      {stuck_pos, _} = :binary.match(html, ~s(data-agents-fleet-health-stat="stuck"))
      assert working_pos < overlay_pos
      assert overlay_pos < stuck_pos
    end
  end

  describe "PM trends section" do
    setup [:register_and_log_in_user]

    test "renders throughput counters, success rate, and cycle time",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # Three completions today: two approved, one rejected (success 67%),
      # with cycle times 10/20/30 (avg 20m).
      for {minutes, status} <- [{10, :approved}, {20, :approved}, {30, :rejected}] do
        {:ok, _} =
          column
          |> task_fixture()
          |> Tasks.update_task(%{
            created_by_agent: "Claude",
            completed_by_agent: "Claude",
            status: :completed,
            completed_at: now,
            time_spent_minutes: minutes,
            review_status: status,
            reviewed_at: now,
            reviewed_by_id: user.id
          })
      end

      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ "data-agents-pm-trends"
      assert pm_trends_value(html, "throughput-today") == "3"
      assert pm_trends_value(html, "throughput-7d") == "3"
      assert pm_trends_value(html, "throughput-30d") == "3"
      assert pm_trends_value(html, "success-rate") == "67%"
    end

    test "shows a prior-period delta with an arrow on the Completed values",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # Two completions today, none in the prior windows -> a +2 upward delta.
      for _ <- 1..2 do
        {:ok, _} =
          column
          |> task_fixture()
          |> Tasks.update_task(%{
            created_by_agent: "Claude",
            completed_by_agent: "Claude",
            status: :completed,
            completed_at: now
          })
      end

      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ "data-agents-pm-trends-delta"
      assert html =~ "hero-arrow-up"
      assert html =~ "+2"
    end

    test "renders the per-day throughput time-series as a bar strip",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # A single completed task (the "single data point" edge case) still
      # renders the full zero-filled 14-day window.
      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          completed_by_agent: "Claude",
          status: :completed,
          completed_at: now
        })

      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ "data-agents-pm-trends-series"
      refute html =~ "data-agents-pm-trends-empty"
      # Default 14-day window -> 14 day buckets.
      assert length(Regex.scan(~r/data-agents-pm-trends-bar=/, html)) == 14
      # Bars use the design-system completion token, not a hardcoded color.
      assert html =~ "var(--st-done)"
      # The strip renders at the taller height for readability.
      assert html =~ "height: 128px"
    end

    test "shows the empty hint and zeroed stats when nothing has completed",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ "data-agents-pm-trends"
      assert html =~ "data-agents-pm-trends-empty"
      refute html =~ "data-agents-pm-trends-series"
      assert pm_trends_value(html, "throughput-today") == "0"
      assert pm_trends_value(html, "success-rate") == "0%"
    end

    test "refreshes the PM trends on an agent_event broadcast",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      {:ok, view, html} = live(conn, ~p"/agents")
      assert pm_trends_value(html, "throughput-today") == "0"

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          completed_by_agent: "Claude",
          status: :completed,
          completed_at: now
        })

      send(view.pid, :refresh_agents_data)

      assert pm_trends_value(render(view), "throughput-today") == "1"
    end

    test "the 30D throughput card is independent of the page time-range selector",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      # Completed 20 days ago and not touched since: inside the trailing 30 days
      # but outside a 7-day selector window. updated_at is backdated too, since
      # the selector-filtered page fetch keys off updated_at — that is exactly the
      # case the bug clamped (the 30D card dropped to 0 under a 7-day selection).
      completed_at =
        DateTime.utc_now() |> DateTime.add(-20 * 86_400, :second) |> DateTime.truncate(:second)

      {:ok, task} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          completed_by_agent: "Claude",
          status: :completed,
          completed_at: completed_at,
          review_status: :approved,
          reviewed_at: completed_at,
          reviewed_by_id: user.id
        })

      backdate_updated_at(
        task,
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(-20 * 86_400, :second)
        |> NaiveDateTime.truncate(:second)
      )

      {:ok, view, html} = live(conn, ~p"/agents")
      # Default :all_time selector already shows the 20-day-old completion in 30D.
      assert pm_trends_value(html, "throughput-30d") == "1"

      # Narrowing the page selector to 7 days must NOT change the 30D card: the
      # throughput cards read from a fixed 60-day window, not the selector set.
      filtered =
        view |> form("#agents-filter-form", %{"time_range" => "last_7_days"}) |> render_change()

      assert pm_trends_value(filtered, "throughput-30d") == "1"
    end
  end

  describe "dormant agents group" do
    setup [:register_and_log_in_user]

    test "shows dormant agents in a collapsed group, excluded from the main roster",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      seed_live_agent(column, "LiveBot")
      seed_dormant_agent(column, "GhostBot")

      {:ok, _view, html} = live(conn, ~p"/agents")
      roster = roster_html(html)

      assert roster =~ "data-agents-dormant-group"
      assert roster =~ "data-agents-dormant-toggle"
      assert roster =~ "Dormant (1)"
      # Live agent sits in the main roster.
      assert roster =~ "LiveBot"
      # Dormant group is collapsed by default, so its cards are not rendered.
      refute roster =~ "data-agent-dormant-card"
      refute roster =~ "GhostBot"
    end

    test "toggling the group reveals and hides the dormant agents with a last-seen label",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      seed_dormant_agent(column, "GhostBot")

      {:ok, view, _html} = live(conn, ~p"/agents")

      expanded = view |> element(~s([data-agents-dormant-toggle])) |> render_click()
      assert expanded =~ "data-agent-dormant-card"
      assert expanded =~ "GhostBot"
      assert expanded =~ "Last seen"

      collapsed = view |> element(~s([data-agents-dormant-toggle])) |> render_click()
      refute collapsed =~ "data-agent-dormant-card"
    end

    test "the expanded/collapsed state survives a live refresh",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      seed_dormant_agent(column, "GhostBot")

      {:ok, view, _html} = live(conn, ~p"/agents")
      view |> element(~s([data-agents-dormant-toggle])) |> render_click()

      send(view.pid, :refresh_agents_data)

      assert render(view) =~ "data-agent-dormant-card"
    end

    test "renders no dormant group when every agent is live",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      seed_live_agent(column, "LiveBot")

      {:ok, _view, html} = live(conn, ~p"/agents")

      refute roster_html(html) =~ "data-agents-dormant-group"
    end
  end

  defp seed_live_agent(column, name) do
    recent = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, _} =
      column
      |> task_fixture()
      |> Tasks.update_task(%{created_by_agent: name, claimed_at: recent, status: :in_progress})
  end

  defp seed_dormant_agent(column, name) do
    stale =
      DateTime.utc_now()
      |> DateTime.add(-15 * 24 * 60 * 60, :second)
      |> DateTime.truncate(:second)

    {:ok, _} =
      column
      |> task_fixture()
      |> Tasks.update_task(%{created_by_agent: name, claimed_at: stale, status: :in_progress})
  end

  describe "agent detail drill-down" do
    setup [:register_and_log_in_user]

    @roster_card_for ~s([data-agent-roster-card][data-agent-name="Claude"])

    test "selecting an agent opens the populated detail panel", %{conn: conn, user: user} do
      board = board_fixture(user)
      seed_working_agent(board, "Claude")

      {:ok, view, html} = live(conn, ~p"/agents")
      refute html =~ "data-agent-detail-panel"

      selected = view |> element(@roster_card_for) |> render_click()

      assert selected =~ "data-agent-detail-panel"
      assert selected =~ "data-agent-detail-name"
      assert selected =~ "Current work"
    end

    test "clearing the filter closes the detail panel", %{conn: conn, user: user} do
      board = board_fixture(user)
      seed_working_agent(board, "Claude")

      {:ok, view, _html} = live(conn, ~p"/agents")
      view |> element(@roster_card_for) |> render_click()
      assert render(view) =~ "data-agent-detail-panel"

      cleared = view |> element(~s([data-clear-agent-filter])) |> render_click()
      refute cleared =~ "data-agent-detail-panel"
    end

    test "selecting the same agent again closes the panel", %{conn: conn, user: user} do
      board = board_fixture(user)
      seed_working_agent(board, "Claude")

      {:ok, view, _html} = live(conn, ~p"/agents")
      view |> element(@roster_card_for) |> render_click()
      assert render(view) =~ "data-agent-detail-panel"

      toggled_off = view |> element(@roster_card_for) |> render_click()
      refute toggled_off =~ "data-agent-detail-panel"
    end

    test "the detail panel refreshes on a broadcast while an agent is selected",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      seed_working_agent(board, "Claude")

      {:ok, view, _html} = live(conn, ~p"/agents")
      view |> element(@roster_card_for) |> render_click()

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, new_task} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          completed_by_agent: "Claude",
          status: :completed,
          completed_at: now
        })

      # The just-created completion is not in the panel until the debounced
      # refresh re-runs load_agents_data.
      refute detail_html(render(view)) =~ new_task.identifier

      send(view.pid, :refresh_agents_data)

      # After the refresh it surfaces inside the detail panel region (not just the feed).
      assert detail_html(render(view)) =~ new_task.identifier
    end

    test "shows No active task for a selected agent without a Doing task",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        column
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Claude",
          completed_by_agent: "Claude",
          status: :completed,
          completed_at: now
        })

      {:ok, view, _html} = live(conn, ~p"/agents")
      selected = view |> element(@roster_card_for) |> render_click()

      assert selected =~ "data-agent-detail-panel"
      assert selected =~ "No active task"
    end

    test "clicking a category toggle collapses then expands that category",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      seed_working_agent(board, "Claude")

      {:ok, view, _html} = live(conn, ~p"/agents")
      view |> element(@roster_card_for) |> render_click()

      # Recent activity is expanded by default, so its event rows render.
      assert detail_html(render(view)) =~ "data-agent-detail-event"

      collapsed =
        view
        |> element(~s([data-agent-detail-section-toggle="activity"]))
        |> render_click()

      # Collapsing hides only the activity body; the panel and other sections stay.
      refute detail_html(collapsed) =~ "data-agent-detail-event"
      assert detail_html(collapsed) =~ "data-agent-detail-panel"
      assert detail_html(collapsed) =~ "Current work"

      expanded =
        view
        |> element(~s([data-agent-detail-section-toggle="activity"]))
        |> render_click()

      assert detail_html(expanded) =~ "data-agent-detail-event"
    end

    test "collapsing one category leaves the others expanded",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      seed_working_agent(board, "Claude")

      {:ok, view, _html} = live(conn, ~p"/agents")
      view |> element(@roster_card_for) |> render_click()

      view
      |> element(~s([data-agent-detail-section-toggle="activity"]))
      |> render_click()

      # The toggled category reflects the collapsed state...
      activity_toggle =
        view |> element(~s([data-agent-detail-section-toggle="activity"])) |> render()

      assert activity_toggle =~ ~s(aria-expanded="false")
      assert activity_toggle =~ "hero-chevron-right"

      # ...while an untouched category stays expanded.
      current_toggle =
        view |> element(~s([data-agent-detail-section-toggle="current"])) |> render()

      assert current_toggle =~ ~s(aria-expanded="true")
      assert current_toggle =~ "hero-chevron-down"
    end
  end

  describe "activity feed timezone and date grouping" do
    setup [:register_and_log_in_user]

    test "the feed groups events under date-header rows", %{conn: conn, user: user} do
      board = board_fixture(user)
      seed_working_agent(board, "Claude")

      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ "data-agent-feed-date-header"
    end

    test "the header cycle-time stat is labeled today-scoped", %{conn: conn, user: user} do
      board = board_fixture(user)
      seed_working_agent(board, "Claude")

      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ "Cycle time · today"
      refute html =~ "Cycle time · avg"
    end

    test "a connect-param timezone threads into the header counters without error",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      seed_working_agent(board, "Claude")

      conn = put_connect_params(conn, %{"timezone" => "America/New_York"})
      {:ok, _view, html} = live(conn, ~p"/agents")

      # The header renders its today counters and today-scoped cycle stat under
      # the supplied zone (the boundary math is covered by the context tests).
      assert html =~ "Approved today"
      assert html =~ "Cycle time · today"
    end

    test "a connect-param timezone renders feed times in that zone",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      seed_claim_at(board, "Claude", ~U[2026-06-20 18:30:00Z])

      conn = put_connect_params(conn, %{"timezone" => "America/New_York"})
      {:ok, _view, html} = live(conn, ~p"/agents")

      # 18:30 UTC is 14:30 in America/New_York (EDT, UTC-4).
      assert html =~ "14:30"
      # The UTC wall-clock time is not shown as the row's visible time.
      refute html =~ ">18:30<"
    end

    test "an unknown connect-param timezone falls back to UTC without crashing",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      seed_claim_at(board, "Claude", ~U[2026-06-20 18:30:00Z])

      conn = put_connect_params(conn, %{"timezone" => "Not/AZone"})
      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ "data-agent-feed"
      assert html =~ "18:30"
    end

    test "the header and Delivery-trends Completed-today values agree under a connect-param timezone",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      tz = "America/New_York"
      {:ok, local_now} = DateTime.now(tz)
      local_today = DateTime.to_date(local_now)
      # Local noon today is unambiguously the user's local today (never near a
      # day boundary) regardless of when the suite runs, so both stats count it.
      {:ok, noon_local} = DateTime.new(local_today, ~T[12:00:00], tz)
      completed_at = noon_local |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)
      seed_completed_at(board, "Claude", completed_at)

      conn = put_connect_params(conn, %{"timezone" => tz})
      {:ok, _view, html} = live(conn, ~p"/agents")

      header_today = marked_value(html, ~s(data-agents-header-kv="completed-today"))
      trends_today = marked_value(html, ~s(data-agents-pm-trends-stat="throughput-today"))

      assert header_today == "1"
      assert header_today == trends_today
    end

    test "the chart's most-recent bar agrees with the local Completed-today value under a connect-param timezone",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      tz = "America/New_York"
      {:ok, local_now} = DateTime.now(tz)
      local_today = DateTime.to_date(local_now)
      # Local noon today is unambiguously the user's local today regardless of
      # when the suite runs, so the most-recent bar must show this completion.
      {:ok, noon_local} = DateTime.new(local_today, ~T[12:00:00], tz)
      completed_at = noon_local |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)
      seed_completed_at(board, "Claude", completed_at)

      conn = put_connect_params(conn, %{"timezone" => tz})
      {:ok, _view, html} = live(conn, ~p"/agents")

      trends_today = marked_value(html, ~s(data-agents-pm-trends-stat="throughput-today"))
      most_recent_bar = bar_count(html, Date.to_iso8601(local_today))

      assert most_recent_bar == "1"
      assert most_recent_bar == trends_today
    end
  end

  defp seed_working_agent(board, name) do
    doing = column_fixture(board, %{name: "Doing"})
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, _} =
      doing
      |> task_fixture()
      |> Tasks.update_task(%{
        created_by_agent: name,
        completed_by_agent: name,
        status: :in_progress,
        claimed_at: now
      })
  end

  # Seeds a single in-progress task claimed by `name` at a fixed UTC instant, so
  # the activity feed surfaces a claim event with a deterministic timestamp the
  # timezone tests can convert and assert against.
  defp seed_claim_at(board, name, %DateTime{} = at) do
    doing = column_fixture(board, %{name: "Doing"})

    {:ok, _} =
      doing
      |> task_fixture()
      |> Tasks.update_task(%{
        created_by_agent: name,
        status: :in_progress,
        claimed_at: at
      })
  end

  # Seeds a single completed task for `name` at a fixed UTC instant so the
  # header and Delivery-trends "Completed today" stats have a deterministic
  # completion to count.
  defp seed_completed_at(board, name, %DateTime{} = at) do
    doing = column_fixture(board, %{name: "Doing"})

    {:ok, _} =
      doing
      |> task_fixture()
      |> Tasks.update_task(%{
        created_by_agent: name,
        completed_by_agent: name,
        status: :completed,
        completed_at: at
      })
  end

  # Reads the trimmed text of the first `<dd>` that follows a given marker
  # attribute in the rendered HTML — used to pull a single stat's value out of a
  # marked card without a full HTML parser.
  defp marked_value(html, marker_attr) do
    [_, after_marker] = String.split(html, marker_attr, parts: 2)
    [_, after_dd_open] = String.split(after_marker, "<dd", parts: 2)
    [_, dd_inner] = String.split(after_dd_open, ">", parts: 2)

    dd_inner
    |> String.split("</dd>", parts: 2)
    |> hd()
    |> String.trim()
  end

  # Reads the count text of the throughput chart bar for a given ISO date — the
  # first `<span>` inside that bar holds the bucket count.
  defp bar_count(html, iso_date) do
    [_, after_bar] = String.split(html, ~s(data-agents-pm-trends-bar="#{iso_date}"), parts: 2)
    [_, after_span_open] = String.split(after_bar, "<span", parts: 2)
    [_, span_inner] = String.split(after_span_open, ">", parts: 2)

    span_inner
    |> String.split("</span>", parts: 2)
    |> hd()
    |> String.trim()
  end

  # Slices the rendered page down to the detail-panel region (between the panel
  # wrapper and the activity feed) so assertions are not confused by content
  # that also appears in the feed.
  defp detail_html(html) do
    case String.split(html, "data-agent-detail", parts: 2) do
      [_, rest] -> rest |> String.split("data-agent-feed", parts: 2) |> hd()
      _ -> ""
    end
  end

  describe "delivery health band" do
    setup [:register_and_log_in_user]

    test "renders the band populated from the scoped delivery rollup", %{conn: conn, user: user} do
      board = board_fixture(user)
      doing = column_fixture(board, %{name: "Doing"})
      target = delivery_target_fixture(user, %{target_date: ~D[2026-07-21]})

      goal = task_fixture(doing, %{type: :goal})
      {:ok, _} = Tasks.update_task(goal, %{target_id: target.id})

      {:ok, _} =
        doing
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Ada",
          parent_id: goal.id,
          status: :in_progress
        })

      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ "data-delivery-health-band"
      # A freshly-created target with incomplete work reads :on_track.
      assert band_count(html, "on-track") == 1
      assert html =~ "Jul 21, 2026"

      # The band sits at the top of the page — above the roster.
      band_pos = :binary.match(html, "data-delivery-health-band") |> elem(0)
      roster_pos = :binary.match(html, "data-agents-roster") |> elem(0)
      assert band_pos < roster_pos
    end

    test "renders the empty state when the user has no targets", %{conn: conn, user: user} do
      board = board_fixture(user)
      board |> column_fixture() |> then(&task_fixture(&1))

      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ "data-delivery-health-band"
      assert html =~ "data-delivery-health-empty"
      assert html =~ "No delivery targets yet."
    end

    test "excludes targets on boards the user cannot access", %{conn: conn, user: user} do
      # The signed-in user's own on-track target.
      board = board_fixture(user)
      doing = column_fixture(board, %{name: "Doing"})
      target = delivery_target_fixture(user, %{target_date: ~D[2026-07-21]})
      goal = task_fixture(doing, %{type: :goal})
      {:ok, _} = Tasks.update_task(goal, %{target_id: target.id})

      # A foreign user's target on an inaccessible board.
      other = user_fixture()
      other_doing = other |> board_fixture() |> column_fixture(%{name: "Doing"})
      foreign = delivery_target_fixture(other, %{target_date: ~D[2026-07-10]})
      foreign_goal = task_fixture(other_doing, %{type: :goal})
      {:ok, _} = Tasks.update_task(foreign_goal, %{target_id: foreign.id})

      {:ok, _view, html} = live(conn, ~p"/agents")

      # Only the user's own target is counted; the foreign one is excluded.
      assert band_count(html, "on-track") == 1
      refute html =~ "Jul 10, 2026"
    end
  end

  # The <dd> count for a delivery-health bucket marker, as an integer.
  defp band_count(html, marker) do
    [_, count] =
      Regex.run(
        ~r/data-delivery-health-stat="#{marker}".*?<dd[^>]*>\s*(\d+)\s*<\/dd>/s,
        html
      )

    String.to_integer(count)
  end

  describe "at-risk target explainer" do
    setup [:register_and_log_in_user]

    test "names the stalled agent and its at-risk target", %{conn: conn, user: user} do
      board = board_fixture(user)
      doing = column_fixture(board, %{name: "Doing"})

      # An at-risk target (created long ago, due soon) with a stuck agent.
      target = delivery_target_fixture(user, %{name: "Launch", target_date: soon_target_date()})
      backdate_target_inserted(target, ~N[2020-01-01 00:00:00])
      goal = task_fixture(doing, %{type: :goal, title: "Ship the API"})
      {:ok, _} = Tasks.update_task(goal, %{target_id: target.id})

      {:ok, _} =
        doing
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Ada",
          parent_id: goal.id,
          status: :in_progress,
          claimed_at: DateTime.add(DateTime.utc_now(), -90 * 60, :second)
        })

      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ "data-target-risk-explainer"
      assert html =~ ~s(data-target-risk-card="#{target.id}")
      assert html =~ "Launch"
      assert html =~ "Ship the API"
      assert html =~ ~s(data-target-risk-agent="Ada")
      assert html =~ "Stuck"
    end

    test "renders nothing when no target is at risk with stalled work",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      doing = column_fixture(board, %{name: "Doing"})
      # An on-track target with a healthy agent — no at-risk explainer.
      target = delivery_target_fixture(user)
      goal = task_fixture(doing, %{type: :goal})
      {:ok, _} = Tasks.update_task(goal, %{target_id: target.id})

      {:ok, _} =
        doing
        |> task_fixture()
        |> Tasks.update_task(%{created_by_agent: "Ada", parent_id: goal.id, status: :in_progress})

      {:ok, _view, html} = live(conn, ~p"/agents")

      refute html =~ "data-target-risk-explainer"
    end
  end

  describe "target-annotated, risk-first roster" do
    setup [:register_and_log_in_user]

    test "orders agents on at-risk targets first and annotates their card",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      doing = column_fixture(board, %{name: "Doing"})

      # At-risk target (created long ago, due soon) with an agent claimed a while
      # ago, so recency alone would NOT put it first.
      at_risk = delivery_target_fixture(user, %{name: "Launch", target_date: soon_target_date()})
      backdate_target_inserted(at_risk, ~N[2020-01-01 00:00:00])
      risky_goal = task_fixture(doing, %{type: :goal, title: "Ship the API"})
      {:ok, _} = Tasks.update_task(risky_goal, %{target_id: at_risk.id})

      {:ok, _} =
        doing
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Risky",
          parent_id: risky_goal.id,
          status: :in_progress,
          claimed_at: DateTime.add(DateTime.utc_now(), -1800, :second)
        })

      # On-track target with a MORE-recent agent (would sort first by recency).
      on_track = delivery_target_fixture(user, %{name: "Steady"})
      calm_goal = task_fixture(doing, %{type: :goal})
      {:ok, _} = Tasks.update_task(calm_goal, %{target_id: on_track.id})

      {:ok, _} =
        doing
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Calm",
          parent_id: calm_goal.id,
          status: :in_progress,
          claimed_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      {:ok, _view, html} = live(conn, ~p"/agents")
      roster = roster_html(html)

      # Risk-first: Risky (at-risk) floats above the more-recent Calm.
      assert {risky_pos, _} = :binary.match(roster, "Risky")
      assert {calm_pos, _} = :binary.match(roster, "Calm")
      assert risky_pos < calm_pos

      # Risky's card carries the target + goal annotation.
      assert roster =~ "data-agent-target-annotation"
      assert roster =~ "Launch"
      assert roster =~ "Ship the API"
    end

    test "an agent with no target renders without the annotation",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      {:ok, _} = column |> task_fixture() |> Tasks.update_task(%{created_by_agent: "Lonely"})

      {:ok, _view, html} = live(conn, ~p"/agents")
      roster = roster_html(html)

      assert roster =~ "Lonely"
      refute roster =~ "data-agent-target-annotation"
    end
  end

  describe "delivery-first layout" do
    setup [:register_and_log_in_user]

    test "renders the delivery tier before the second tier", %{conn: conn, user: user} do
      board = board_fixture(user)
      board |> column_fixture() |> then(&task_fixture(&1))

      {:ok, _view, html} = live(conn, ~p"/agents")

      assert {delivery_pos, _} = :binary.match(html, "data-agents-delivery-tier")
      assert {second_pos, _} = :binary.match(html, "data-agents-second-tier")
      assert delivery_pos < second_pos

      # The delivery band + explainer live in the delivery tier, above the roster.
      assert {band_pos, _} = :binary.match(html, "data-delivery-health-band")
      assert {roster_pos, _} = :binary.match(html, "data-agents-roster")
      assert band_pos < second_pos
      assert delivery_pos < band_pos and band_pos < roster_pos
    end

    test "keeps the second-tier components (roster, pm-trends, feed) present",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      {:ok, _} = column |> task_fixture() |> Tasks.update_task(%{created_by_agent: "Claude"})

      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ "data-agents-roster"
      assert html =~ "data-agents-pm-trends"
      assert html =~ "data-agent-feed"
    end

    test "tethers a feed entry to the target and goal its agent serves",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      doing = column_fixture(board, %{name: "Doing"})
      target = delivery_target_fixture(user, %{name: "Launch"})
      goal = task_fixture(doing, %{type: :goal, title: "Ship the API"})
      {:ok, _} = Tasks.update_task(goal, %{target_id: target.id})

      {:ok, _} =
        doing
        |> task_fixture()
        |> Tasks.update_task(%{
          created_by_agent: "Ada",
          parent_id: goal.id,
          status: :in_progress,
          claimed_at: DateTime.add(DateTime.utc_now(), -300, :second)
        })

      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ "data-agent-feed-tether"
      # The feed row for Ada's claim is tethered to its target and goal.
      feed = feed_html(html)
      assert feed =~ "Launch"
      assert feed =~ "Ship the API"
    end
  end

  describe "reassign action" do
    setup [:register_and_log_in_user]

    test "shows a Reassign control and dialog listing the goal + not-started children",
         %{conn: conn, user: user} do
      %{goal: goal, backlog: backlog} = at_risk_goal_with_children(user)
      backlog_child = task_fixture(backlog, %{parent_id: goal.id, title: "Wire it up"})

      {:ok, view, _html} = live(conn, ~p"/agents")

      assert has_element?(view, ~s([data-reassign-trigger="#{goal.id}"]))

      html = view |> element(~s([data-reassign-trigger="#{goal.id}"])) |> render_click()

      assert html =~ "reassign-goal-modal"
      # Goal + the one not-started child = 2 affected tasks, both listed.
      assert html =~ goal.identifier
      assert html =~ backlog_child.identifier
      assert html =~ "Wire it up"
      assert html =~ "2 tasks"
    end

    test "confirming reassigns the goal and its not-started children, leaving Doing untouched",
         %{conn: conn, user: user} do
      %{goal: goal, board: board, ready: ready, doing: doing} = at_risk_goal_with_children(user)
      other = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, other, :modify, user)
      ready_child = task_fixture(ready, %{parent_id: goal.id})
      doing_child = task_fixture(doing, %{parent_id: goal.id, status: :in_progress})

      {:ok, view, _html} = live(conn, ~p"/agents")
      view |> element(~s([data-reassign-trigger="#{goal.id}"])) |> render_click()

      html =
        view
        |> form("#reassign-form", %{"assigned_to_id" => to_string(other.id)})
        |> render_submit()

      assert html =~ "Reassigned"
      assert Repo.get!(Kanban.Tasks.Task, goal.id).assigned_to_id == other.id
      assert Repo.get!(Kanban.Tasks.Task, ready_child.id).assigned_to_id == other.id
      # The in-progress Doing child keeps its (nil) assignee.
      assert Repo.get!(Kanban.Tasks.Task, doing_child.id).assigned_to_id == nil
      # Dialog closed after a successful write.
      refute has_element?(view, "#reassign-goal-modal")
    end

    test "surfaces tasks skipped because they were claimed since the dialog opened",
         %{conn: conn, user: user} do
      %{goal: goal, board: board, ready: ready, backlog: backlog} =
        at_risk_goal_with_children(user)

      other = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, other, :modify, user)
      _open_child = task_fixture(ready, %{parent_id: goal.id})
      claimed = task_fixture(backlog, %{parent_id: goal.id, status: :in_progress})

      {:ok, view, _html} = live(conn, ~p"/agents")
      view |> element(~s([data-reassign-trigger="#{goal.id}"])) |> render_click()

      html =
        view
        |> form("#reassign-form", %{"assigned_to_id" => to_string(other.id)})
        |> render_submit()

      assert html =~ "Skipped"
      assert html =~ claimed.identifier
      assert Repo.get!(Kanban.Tasks.Task, claimed.id).assigned_to_id == nil
    end

    test "does not render the Reassign control for a user who cannot intervene",
         %{conn: conn, user: viewer} do
      # The goal lives on another owner's board; the viewer is only a read-only
      # member, so can_intervene?/2 is false and no control renders.
      owner = user_fixture()
      %{goal: goal, board: board} = at_risk_goal_with_children(owner)
      {:ok, _} = Boards.add_user_to_board(board, viewer, :read_only, owner)

      {:ok, view, _html} = live(conn, ~p"/agents")

      refute has_element?(view, ~s([data-reassign-trigger="#{goal.id}"]))
    end
  end

  # Builds an at-risk target with a stalled agent on a fresh goal, plus Backlog
  # and Ready columns for not-started children, all owned by `owner`. Returns the
  # goal and the columns so a test can attach children in specific states.
  defp at_risk_goal_with_children(owner) do
    board = board_fixture(owner)
    doing = column_fixture(board, %{name: "Doing"})
    backlog = column_fixture(board, %{name: "Backlog"})
    ready = column_fixture(board, %{name: "Ready"})

    target = delivery_target_fixture(owner, %{name: "Launch", target_date: soon_target_date()})
    backdate_target_inserted(target, ~N[2020-01-01 00:00:00])
    goal = task_fixture(doing, %{type: :goal, title: "Ship the API"})
    {:ok, goal} = Tasks.update_task(goal, %{target_id: target.id})

    # A stalled (stuck) agent on the goal makes it surface in the at-risk explainer.
    {:ok, _} =
      doing
      |> task_fixture()
      |> Tasks.update_task(%{
        created_by_agent: "Ada",
        parent_id: goal.id,
        status: :in_progress,
        claimed_at: DateTime.add(DateTime.utc_now(), -90 * 60, :second)
      })

    %{goal: goal, board: board, doing: doing, backlog: backlog, ready: ready, target: target}
  end

  # The activity-feed region of the page (from its section marker onward).
  defp feed_html(html) do
    [_, feed] = String.split(html, "data-agent-feed", parts: 2)
    feed
  end

  # A target_date far enough ahead that, paired with a long-ago inserted_at,
  # the elapsed calendar share outruns the (zero) work share -> :at_risk.
  defp soon_target_date, do: Date.add(Date.utc_today(), 20)

  defp backdate_target_inserted(%{id: id}, %NaiveDateTime{} = at) do
    from(t in Kanban.Targets.DeliveryTarget, where: t.id == ^id)
    |> Repo.update_all(set: [inserted_at: at])
  end
end
