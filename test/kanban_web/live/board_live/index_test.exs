defmodule KanbanWeb.BoardLive.IndexTest do
  @moduledoc """
  Page-level regression for D123: the boards page (TargetsStrip), the
  target-detail page, and the agents delivery-health band must show the SAME
  status for the same delivery target and the same viewer.

  The three surfaces now all anchor status on the viewer's browser-local
  calendar day (via `KanbanWeb.Timezone.browser_timezone/1` +
  `Kanban.Timezone.local_today/1`), so they can no longer split the way the
  original bug did (boards/detail on server UTC, agents on viewer-local).

  Also covers W1915: the workspace header (aggregated To Do/Doing/Review/Done
  counts plus the deduplicated people-and-agents avatar stack) and the
  below-title Agents/Review queue/Metrics nav strip, including that both stay
  in step with the 30s `:refresh_metrics` poll and never leak another user's
  boards.
  """
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TargetsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Boards
  alias Kanban.Repo
  alias Kanban.Targets.DeliveryTarget
  alias Kanban.Tasks

  describe "cross-page delivery-target status agreement (D123)" do
    setup [:register_and_log_in_user]

    test "boards page, target detail, and agents band agree for a west-of-UTC viewer",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      doing = column_fixture(board, %{name: "Doing"})

      # A target 40 days into a 50-day window with no completed work is at-risk
      # (elapsed ~0.8, work 0.0) for any nearby calendar day, so the assertion
      # is deterministic regardless of the viewer's timezone.
      today = Date.utc_today()
      created_on = Date.add(today, -40)
      target_date = Date.add(today, 10)

      target =
        delivery_target_fixture(user, %{name: "Ships soon", target_date: target_date})

      backdate_target(target, NaiveDateTime.new!(created_on, ~T[00:00:00]))

      goal = goal_on_target(doing, target)
      _incomplete_child = task_fixture(doing, %{parent_id: goal.id})

      # The timezone class that triggered the original split: a viewer west of
      # UTC whose local calendar day can trail the server's UTC day.
      conn = put_connect_params(conn, %{"timezone" => "America/Los_Angeles"})

      {:ok, _boards, boards_html} = live(conn, ~p"/boards")
      assert boards_html =~ "At-risk"

      {:ok, _detail, detail_html} = live(conn, ~p"/targets/#{target.id}")
      assert detail_html =~ "At-risk"

      {:ok, _agents, agents_html} = live(conn, ~p"/agents")
      assert band_count(agents_html, "at-risk") == 1
      assert band_count(agents_html, "on-track") == 0
    end
  end

  describe "archived targets" do
    setup [:register_and_log_in_user]

    test "the header links to the archived targets page", %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      target = delivery_target_fixture(user, %{name: "Active Target"})
      goal_on_target(column, target)

      {:ok, live, _html} = live(conn, ~p"/boards")

      assert has_element?(live, "a[data-archived-targets-link][href='/targets/archived']")
    end

    test "the archived link stays visible when every target is archived",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)
      target = delivery_target_fixture(user, %{name: "Gone Target"})
      goal_on_target(column, target)
      archive!(target)

      {:ok, live, _html} = live(conn, ~p"/boards")

      # The link lives in the always-visible header actions, not beside the
      # TargetsStrip — the strip is wrapped in :if={@targets != []}, so a link
      # placed there would disappear exactly when the user has archived
      # everything and most needs a way back to it.
      assert has_element?(live, "a[data-archived-targets-link][href='/targets/archived']")
    end

    test "an archived target no longer appears on the boards page",
         %{conn: conn, user: user} do
      board = board_fixture(user)
      column = column_fixture(board)

      active = delivery_target_fixture(user, %{name: "Still Shipping"})
      goal_on_target(column, active)

      archived = delivery_target_fixture(user, %{name: "Already Shipped"})
      goal_on_target(column, archived)
      archive!(archived)

      {:ok, _live, html} = live(conn, ~p"/boards")

      # The exclusion comes from the is_nil(archived_at) filter W1701 added to
      # list_targets/1, which list_targets_with_status/2 composes.
      assert html =~ "Still Shipping"
      refute html =~ "Already Shipped"
    end
  end

  # Pulls the integer count rendered in the delivery-health band stat tile for a
  # given status marker (on-track / at-risk / missed / complete).
  defp band_count(html, marker) do
    [_, count] =
      Regex.run(
        ~r/data-delivery-health-stat="#{marker}".*?<dd[^>]*>\s*(\d+)\s*<\/dd>/s,
        html
      )

    String.to_integer(count)
  end

  defp goal_on_target(column, target) do
    goal = task_fixture(column, %{type: :goal})
    {:ok, goal} = Tasks.update_task(goal, %{target_id: target.id})
    goal
  end

  # archived_at is only castable through DeliveryTarget.archive_changeset/2, so
  # change/2 stamps it directly, bypassing the cast allow-list.
  defp archive!(%DeliveryTarget{} = target) do
    target
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now())
    |> Repo.update!()
  end

  defp backdate_target(%DeliveryTarget{id: id}, %NaiveDateTime{} = at) do
    from(t in DeliveryTarget, where: t.id == ^id)
    |> Repo.update_all(set: [inserted_at: at])
  end

  describe "workspace header and nav strip (W1915)" do
    setup [:register_and_log_in_user]

    test "renders the aggregated counts across every board the viewer can access",
         %{conn: conn, user: user} do
      a = ai_optimized_board_fixture(user, %{name: "Alpha Board"})
      b = ai_optimized_board_fixture(user, %{name: "Bravo Board"})
      cols_a = columns_by_name(a)
      cols_b = columns_by_name(b)

      for _ <- 1..2, do: task_fixture(cols_a["Ready"])
      _ = task_fixture(cols_a["Doing"])
      _ = task_fixture(cols_a["Review"])
      for _ <- 1..3, do: task_fixture(cols_a["Done"])

      _ = task_fixture(cols_b["Backlog"])
      for _ <- 1..2, do: task_fixture(cols_b["Doing"])
      for _ <- 1..4, do: task_fixture(cols_b["Done"])

      {:ok, _live, html} = live(conn, ~p"/boards")

      assert header_count(html, "to-do") == 3
      assert header_count(html, "doing") == 3
      assert header_count(html, "review") == 1
      assert header_count(html, "done") == 7
    end

    test "renders the stat cluster in the title row, above the nav strip",
         %{conn: conn, user: user} do
      _board = ai_optimized_board_fixture(user, %{name: "Order Board"})

      {:ok, _live, html} = live(conn, ~p"/boards")

      {title, _} = :binary.match(html, "</h1>")
      {stats, _} = :binary.match(html, ~s(data-boards-header-kv="to-do"))
      {strip, _} = :binary.match(html, "boards-nav-strip")

      assert title < stats
      assert stats < strip
    end

    test "a single board's counts are its own", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user, %{name: "Solo Board"})
      cols = columns_by_name(board)

      _ = task_fixture(cols["Ready"])
      for _ <- 1..2, do: task_fixture(cols["Done"])

      {:ok, _live, html} = live(conn, ~p"/boards")

      assert header_count(html, "to-do") == 1
      assert header_count(html, "doing") == 0
      assert header_count(html, "review") == 0
      assert header_count(html, "done") == 2
    end

    test "renders one deduplicated avatar per person and agent across boards",
         %{conn: conn, user: user} do
      teammate = user_fixture(%{name: "Ada Lovelace"})
      a = ai_optimized_board_fixture(user, %{name: "Roster Alpha"})
      b = ai_optimized_board_fixture(user, %{name: "Roster Bravo"})
      {:ok, _} = Boards.add_user_to_board(a, teammate, :modify, user)
      {:ok, _} = Boards.add_user_to_board(b, teammate, :modify, user)

      # The same agent completing work on BOTH boards must collapse to one avatar.
      complete_by_agent(columns_by_name(a)["Done"], "Claude")
      complete_by_agent(columns_by_name(b)["Done"], "Claude")

      {:ok, live, html} = live(conn, ~p"/boards")

      assert html =~ "data-boards-header-members"

      # Scoped to the workspace stack on purpose: each board CARD renders its
      # own member stack too, so a page-wide count would see Ada once per
      # board and prove nothing about workspace-level dedup. The trailing `>`
      # excludes the stack's comma-joined roster title on the outer span.
      members_html = live |> element("[data-boards-header-members]") |> render()

      assert occurrences(members_html, ~s(title="Ada Lovelace">)) == 1
      assert occurrences(members_html, ~s(title="Claude">)) == 1
    end

    test "renders the three workspace links in the nav strip", %{conn: conn, user: user} do
      _board = ai_optimized_board_fixture(user, %{name: "Links Board"})

      {:ok, live, _html} = live(conn, ~p"/boards")

      # Scoped to the strip deliberately: Layouts.app's side nav already emits
      # all three hrefs on this page, so a bare `html =~ href="/agents"` would
      # pass even with the strip absent entirely.
      assert has_element?(live, ~s(nav.boards-nav-strip a[href="/agents"]))
      assert has_element?(live, ~s(nav.boards-nav-strip a[href="/review"]))
      assert has_element?(live, ~s(nav.boards-nav-strip a[href="/metrics"]))

      # No self-link back to the page it sits on, and nothing marked current.
      refute has_element?(live, ~s(nav.boards-nav-strip a[href="/boards"]))
      refute has_element?(live, ~s(nav.boards-nav-strip a[aria-current="page"]))
    end

    test "the refresh poll recomputes the counts without a remount",
         %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user, %{name: "Refresh Board"})
      cols = columns_by_name(board)
      task = task_fixture(cols["Doing"])

      {:ok, live, html} = live(conn, ~p"/boards")
      assert header_count(html, "doing") == 1
      assert header_count(html, "done") == 0

      pid = live.pid
      {:ok, _moved} = Tasks.move_task(task, cols["Done"], 0)

      # The poll timer is disabled in the test config, so drive the handler
      # directly — the same way the existing Index refresh tests do.
      send(pid, :refresh_metrics)
      html = render(live)

      assert header_count(html, "doing") == 0
      assert header_count(html, "done") == 1

      # The originally-mounted process is still serving, so the aggregates
      # were re-derived in place rather than recovered by a remount. (A pid
      # identity check would be tautological here — `render/1` returns HTML,
      # so `live` is never rebound.)
      assert Process.alive?(pid)
    end

    test "an agent that appears between polls joins the avatar stack",
         %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user, %{name: "Late Agent Board"})

      {:ok, live, html} = live(conn, ~p"/boards")
      refute html =~ ~s(title="Cursor")

      complete_by_agent(columns_by_name(board)["Done"], "Cursor")

      send(live.pid, :refresh_metrics)
      html = render(live)

      assert html =~ ~s(title="Cursor")
    end

    test "deleting a board updates the header immediately", %{conn: conn, user: user} do
      keep = ai_optimized_board_fixture(user, %{name: "Keeper Board"})
      drop = ai_optimized_board_fixture(user, %{name: "Doomed Board"})

      _ = task_fixture(columns_by_name(keep)["Ready"])
      for _ <- 1..3, do: task_fixture(columns_by_name(drop)["Done"])

      {:ok, live, html} = live(conn, ~p"/boards")
      assert header_count(html, "done") == 3

      html =
        live
        |> element(~s(#boards-#{drop.id} a[aria-label="Delete board"]))
        |> render_click()

      # Without the post-delete recompute this would still read 3 until the
      # next 30s poll.
      assert header_count(html, "done") == 0
      assert header_count(html, "to-do") == 1
    end

    test "zero boards: no stat cluster, but the nav strip and empty state remain",
         %{conn: conn} do
      {:ok, live, html} = live(conn, ~p"/boards")

      refute html =~ "data-boards-header-kv"
      assert has_element?(live, ~s(nav.boards-nav-strip a[href="/agents"]))

      # Assert on empty-state-specific markup: the literal "Boards" also
      # appears in the breadcrumb, the h1 and the page title, so it would
      # hold even with the empty state deleted outright.
      assert html =~ "No boards yet."
      assert has_element?(live, ~s(a[href="/boards/new"]))
    end

    test "one user's header never reflects another user's boards",
         %{conn: conn, user: user} do
      mine = ai_optimized_board_fixture(user, %{name: "My Own Board"})
      _ = task_fixture(columns_by_name(mine)["Doing"])

      stranger = user_fixture(%{name: "Mallory Stranger"})
      theirs = ai_optimized_board_fixture(stranger, %{name: "Stranger Board"})
      their_cols = columns_by_name(theirs)
      for _ <- 1..5, do: task_fixture(their_cols["Done"])
      complete_by_agent(their_cols["Done"], "StrangerAgent")

      {:ok, _live, html} = live(conn, ~p"/boards")

      assert header_count(html, "doing") == 1
      assert header_count(html, "done") == 0
      refute html =~ "Mallory Stranger"
      refute html =~ "StrangerAgent"
    end

    test "a populated page emits no theme-blind utility classes", %{conn: conn, user: user} do
      # KanbanWeb.DarkModeRegressionTest GETs /boards too, but with a fresh
      # board-less user — so it never renders the header, which is gated on
      # @has_boards. This is the populated-page counterpart.
      #
      # The check is scoped to the two regions this task adds rather than the
      # whole page: page chrome legitimately carries allow-listed markers
      # (e.g. the bg-black/40 drawer backdrop), and whole-page coverage is
      # already DarkModeRegressionTest's job. Only the class pattern is
      # applied, not that test's inline oklch/hex ones — the avatar palette is
      # deliberately theme-blind and allow-listed in avatar.ex.
      class_violation =
        ~r/(?<![\w-])(text-gray-\d+|bg-gray-\d+|border-gray-\d+|bg-white|text-white|text-black|bg-black)(?![\w-])/

      board = ai_optimized_board_fixture(user, %{name: "Themed Board"})
      cols = columns_by_name(board)
      _ = task_fixture(cols["Doing"])
      complete_by_agent(cols["Done"], "Claude")

      {:ok, live, html} = live(conn, ~p"/boards")

      assert html =~ "data-boards-header-kv"
      assert html =~ "boards-nav-strip"

      header_html = live |> element("[data-boards-header]") |> render()
      strip_html = live |> element("nav.boards-nav-strip") |> render()

      refute Regex.match?(class_violation, header_html)
      refute Regex.match?(class_violation, strip_html)
    end

    test "an agent name containing markup is escaped", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user, %{name: "Escaping Board"})

      # completed_by_agent is free-form with no changeset validation, unlike
      # User.name which rejects markup outright — so this is the reachable path.
      complete_by_agent(columns_by_name(board)["Done"], "<script>alert(1)</script>")

      {:ok, _live, html} = live(conn, ~p"/boards")

      refute html =~ "<script>alert(1)"
      assert html =~ "&lt;script&gt;"
    end
  end

  # kv/1 renders <div data-boards-header-kv="doing" ...><span>Doing</span><span>3</span></div>.
  # Isolate one card first so two cards holding the same value stay distinguishable.
  defp header_count(html, marker) do
    [card] = Regex.run(~r/<div data-boards-header-kv="#{marker}".*?<\/div>/s, html)
    [_, count] = Regex.run(~r/>\s*(\d+)\s*</, card)
    String.to_integer(count)
  end

  defp occurrences(html, needle), do: length(String.split(html, needle)) - 1

  defp columns_by_name(board) do
    board |> Repo.preload(:columns) |> Map.fetch!(:columns) |> Map.new(&{&1.name, &1})
  end

  # A workspace "agent" is a distinct completed_by_agent stamped on a task
  # completed inside the 14-day pulse window. The LiveView calls
  # list_workspace_members/1 with the default :now, so this must use real time.
  defp complete_by_agent(column, agent_name) do
    task = task_fixture(column, %{title: "Done by #{agent_name} #{System.unique_integer()}"})

    {:ok, task} =
      Tasks.update_task(task, %{completed_at: DateTime.utc_now(), completed_by_agent: agent_name})

    task
  end
end
