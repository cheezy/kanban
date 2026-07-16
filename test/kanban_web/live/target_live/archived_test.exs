defmodule KanbanWeb.TargetLive.ArchivedTest do
  @moduledoc """
  Route-ordering, listing, scoping and unarchive-event contract tests for
  `KanbanWeb.TargetLive.Archived` — the `/targets/archived` page.
  """
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TargetsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Repo
  alias Kanban.Targets
  alias Kanban.Targets.DeliveryTarget

  defp goal_fixture(column, attrs) do
    task_fixture(column, Map.merge(%{type: :goal}, attrs))
  end

  # archived_at is only castable through archive_changeset/2, so change/2 sets it
  # directly, bypassing the cast allow-list. This keeps the fixture independent
  # of the :complete derivation archive_target/2 requires.
  defp archive!(%DeliveryTarget{} = target) do
    target
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now())
    |> Repo.update!()
  end

  # An archived target visible to `scope`: visibility is board-scoped through a
  # member goal, so a target with no goal on an accessible board would NOT list.
  defp visible_archived_target(scope, owner, column, attrs \\ %{}) do
    target = delivery_target_fixture(owner, attrs)
    goal = goal_fixture(column, %{title: "Member Goal"})
    assert {:ok, _} = Targets.assign_goal(scope, goal, target)

    archive!(target)
  end

  # The visible text of each span inside a row's link, in document order, with
  # runs of whitespace collapsed (HEEx interpolation leaves newlines and indent
  # between the interpolated parts) and the layout's empty spacer span dropped.
  defp row_span_texts(live, %DeliveryTarget{} = target) do
    live
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-target-id='#{target.id}'] [data-archived-target-link] span")
    |> Enum.map(fn node ->
      node |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()
    end)
    |> Enum.reject(&(&1 == ""))
  end

  describe "routing" do
    setup [:register_and_log_in_user]

    test "/targets/archived renders the Archived page, not TargetLive.Show", %{conn: conn} do
      {:ok, live, html} = live(conn, ~p"/targets/archived")

      # Proves the literal segment is not swallowed by /targets/:id: Show would
      # raise Ecto.Query.CastError on the uncastable id "archived", so reaching
      # the Archived screen at all means the literal route matched first.
      assert has_element?(live, "[data-archived-targets-screen]")
      refute has_element?(live, "[data-target-show]")
      assert html =~ "Archived targets"
    end
  end

  describe "mount/3" do
    setup [:register_and_log_in_user]

    test "lists the user's board-visible archived targets", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      board = board_fixture(user)
      column = column_fixture(board)
      visible_archived_target(scope, user, column, %{name: "Shipped Q1"})

      {:ok, live, html} = live(conn, ~p"/targets/archived")

      assert html =~ "Shipped Q1"
      assert has_element?(live, "[data-archived-target-row]")
      refute has_element?(live, "[data-archived-targets-empty]")
    end

    test "does not list active (unarchived) targets", %{conn: conn, user: user, scope: scope} do
      board = board_fixture(user)
      column = column_fixture(board)
      target = delivery_target_fixture(user, %{name: "Still Active"})
      goal = goal_fixture(column, %{title: "Live Goal"})
      assert {:ok, _} = Targets.assign_goal(scope, goal, target)

      {:ok, _live, html} = live(conn, ~p"/targets/archived")

      refute html =~ "Still Active"
    end

    test "does not list an archived target with no member goal on an accessible board",
         %{conn: conn, user: user} do
      user |> delivery_target_fixture(%{name: "Orphan Target"}) |> archive!()

      {:ok, live, html} = live(conn, ~p"/targets/archived")

      refute html =~ "Orphan Target"
      assert has_element?(live, "[data-archived-targets-empty]")
    end

    test "does not list an archived target on another user's board", %{conn: conn} do
      other_user = user_fixture()
      other_board = board_fixture(other_user)
      other_column = column_fixture(other_board)
      other_scope = Scope.for_user(other_user)
      visible_archived_target(other_scope, other_user, other_column, %{name: "Their Target"})

      {:ok, live, html} = live(conn, ~p"/targets/archived")

      refute html =~ "Their Target"
      assert has_element?(live, "[data-archived-targets-empty]")
    end
  end

  describe "mount/3 — anonymous" do
    test "redirects to the login page", %{conn: conn} do
      # The route lives in the :require_authenticated_user live_session, so an
      # anonymous caller never reaches load_targets/1 — which would otherwise
      # raise on a scope with no user.
      assert {:error, {:redirect, %{to: redirect_to}}} = live(conn, ~p"/targets/archived")
      assert redirect_to =~ "/users/log-in"
    end
  end

  describe "row rendering" do
    setup [:register_and_log_in_user]

    test "formats the target date and renders the archived age", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      board = board_fixture(user)
      column = column_fixture(board)
      visible_archived_target(scope, user, column, %{name: "Dated", target_date: ~D[2026-03-01]})

      {:ok, _live, html} = live(conn, ~p"/targets/archived")

      # format_date/1 renders the Date through Calendar.strftime with a
      # day-of-month that is not zero-padded ("%-d"), so the 1st is "Mar 1",
      # never "Mar 01".
      assert html =~ "Mar 1, 2026"
      refute html =~ "Mar 01, 2026"
      # archive!/1 stamps archived_at at utc_now, which TimeAgo's :coarse
      # granularity labels "just now" under a minute.
      assert html =~ "Archived just now"
    end

    test "renders the description when the target has one", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      board = board_fixture(user)
      column = column_fixture(board)

      target =
        visible_archived_target(scope, user, column, %{
          name: "Described",
          description: "Ships the billing rewrite"
        })

      {:ok, live, html} = live(conn, ~p"/targets/archived")

      assert html =~ "Ships the billing rewrite"
      # The description renders directly beneath the name, inside the row link.
      assert ["Described", "Ships the billing rewrite" | _] = row_span_texts(live, target)
    end

    test "omits the description element when the target has none", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      board = board_fixture(user)
      column = column_fixture(board)
      target = visible_archived_target(scope, user, column, %{name: "Bare"})

      assert is_nil(target.description)

      {:ok, live, html} = live(conn, ~p"/targets/archived")

      assert html =~ "Bare"
      # The :if guard drops the description span entirely rather than rendering
      # an empty one, so the only non-empty spans left in the row's label stack
      # are the name, the target date and the archived age.
      assert ["Bare", "Target date: Dec 31, 2026", "Archived just now"] =
               row_span_texts(live, target)
    end

    test "renders the archived target count next to the heading", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      board = board_fixture(user)
      column = column_fixture(board)
      visible_archived_target(scope, user, column, %{name: "One"})
      visible_archived_target(scope, user, column, %{name: "Two"})

      {:ok, live, _html} = live(conn, ~p"/targets/archived")

      assert live |> element("[data-archived-targets-screen] .ident") |> render() =~ "2"
    end
  end

  describe "empty state" do
    setup [:register_and_log_in_user]

    test "renders the empty message when there are no archived targets", %{conn: conn} do
      {:ok, live, html} = live(conn, ~p"/targets/archived")

      assert has_element?(live, "[data-archived-targets-empty]")
      assert html =~ "No archived targets."
      refute has_element?(live, "[data-archived-target-row]")
    end
  end

  describe "unarchive event" do
    setup [:register_and_log_in_user]

    test "renders the Unarchive button with a confirm prompt", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      board = board_fixture(user)
      column = column_fixture(board)
      target = visible_archived_target(scope, user, column)

      {:ok, live, html} = live(conn, ~p"/targets/archived")

      assert has_element?(live, "[data-unarchive-target][phx-value-id='#{target.id}']")
      assert html =~ "Unarchive"
      # data-confirm gates the click browser-side. LiveViewTest cannot drive the
      # browser dialog, so the attribute's presence is the assertable proof — the
      # context re-checks ownership regardless.
      assert html =~ "data-confirm"
      assert html =~ "Unarchive this target?"
    end

    test "unarchiving an owned target flashes success, clears archived_at and drops the row",
         %{conn: conn, user: user, scope: scope} do
      board = board_fixture(user)
      column = column_fixture(board)
      target = visible_archived_target(scope, user, column, %{name: "Recoverable"})

      {:ok, live, html} = live(conn, ~p"/targets/archived")
      assert html =~ "Recoverable"

      result =
        live
        |> element("[data-unarchive-target][phx-value-id='#{target.id}']")
        |> render_click()

      assert result =~ "Target unarchived successfully"
      # Live re-render, no full page reload: the row is gone from the same LiveView.
      refute result =~ "Recoverable"
      assert has_element?(live, "[data-archived-targets-empty]")
      assert is_nil(Repo.get!(DeliveryTarget, target.id).archived_at)
    end

    test "unarchiving a board-visible but not-owned target flashes an error and keeps the row",
         %{conn: conn, user: user, scope: scope} do
      other_user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      # THE ASYMMETRY: listing is board-scoped, unarchive is owner-scoped. The
      # goal lives on the caller's board, so the row renders; the target belongs
      # to other_user, so unarchive_target/2 refuses.
      target = visible_archived_target(scope, other_user, column, %{name: "Not Mine"})

      {:ok, live, html} = live(conn, ~p"/targets/archived")
      assert html =~ "Not Mine"

      result = render_click(live, "unarchive", %{"id" => to_string(target.id)})

      assert result =~ "Target not found"
      assert result =~ "Not Mine"
      assert has_element?(live, "[data-archived-target-row]")
      refute is_nil(Repo.get!(DeliveryTarget, target.id).archived_at)
    end

    test "a non-numeric id flashes an error instead of crashing the LiveView",
         %{conn: conn, user: user, scope: scope} do
      board = board_fixture(user)
      column = column_fixture(board)
      visible_archived_target(scope, user, column, %{name: "Untouched"})

      {:ok, live, _html} = live(conn, ~p"/targets/archived")

      # The id arrives from the client over the socket, so it is not trustworthy.
      # Unparsed, "abc" would raise Ecto.Query.CastError in the context query and
      # take this LiveView process down.
      result = render_click(live, "unarchive", %{"id" => "abc"})

      assert result =~ "Target not found"
      assert result =~ "Untouched"
    end

    test "an out-of-range id flashes not-found instead of crashing the LiveView",
         %{conn: conn, user: user, scope: scope} do
      board = board_fixture(user)
      column = column_fixture(board)
      visible_archived_target(scope, user, column, %{name: "Out Of Range"})

      {:ok, live, _html} = live(conn, ~p"/targets/archived")

      # Integer.parse/1 is unbounded, so 2^63 parses cleanly and would then raise
      # DBConnection.EncodeError when Ecto encoded it as a bigint parameter —
      # taking this LiveView down. Out-of-range is indistinguishable from missing,
      # so it reuses the not-found branch rather than a new message. (D149)
      result = render_click(live, "unarchive", %{"id" => "9223372036854775808"})

      assert result =~ "Target not found"
      assert result =~ "Out Of Range"

      # LiveView params are JSON-decoded, so a crafted event can deliver a bare
      # number rather than a string — that reaches the is_integer clause, which
      # Integer.parse never sees. Guarding only the string path leaves this open.
      result = render_click(live, "unarchive", %{"id" => 9_223_372_036_854_775_808})

      assert result =~ "Target not found"
      assert result =~ "Out Of Range"
    end

    test "a zero or negative id flashes not-found",
         %{conn: conn, user: user, scope: scope} do
      board = board_fixture(user)
      column = column_fixture(board)
      visible_archived_target(scope, user, column, %{name: "Still Archived"})

      {:ok, live, _html} = live(conn, ~p"/targets/archived")

      # Ids are positive serials, so the guard's 1.. lower bound rejects 0 and
      # negatives. This locks in that intent across both the string and
      # JSON-number shapes — it does not prove the guard is what rejected them:
      # without it, 0/-1 simply match no row and reach this same branch.
      for id <- ["0", "-1", 0, -1] do
        result = render_click(live, "unarchive", %{"id" => id})

        assert result =~ "Target not found"
        assert result =~ "Still Archived"
      end
    end

    test "an integer id is accepted and unarchives the target", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      board = board_fixture(user)
      column = column_fixture(board)
      target = visible_archived_target(scope, user, column, %{name: "Integer Id"})

      {:ok, live, _html} = live(conn, ~p"/targets/archived")

      # phx-value-id always arrives as a string from the DOM, but an event pushed
      # programmatically (a JS hook's pushEvent) carries the id's JSON type — an
      # integer. parse_id/1 has a clause for it, so it must not fall through to
      # the not-found branch.
      result = render_click(live, "unarchive", %{"id" => target.id})

      assert result =~ "Target unarchived successfully"
      assert is_nil(Repo.get!(DeliveryTarget, target.id).archived_at)
    end

    test "a non-scalar id flashes an error instead of crashing the LiveView", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      board = board_fixture(user)
      column = column_fixture(board)
      target = visible_archived_target(scope, user, column, %{name: "Untouched"})

      {:ok, live, _html} = live(conn, ~p"/targets/archived")

      # Neither a binary nor an integer: the catch-all clause refuses it rather
      # than letting a list reach the context query, where it would raise
      # Ecto.Query.CastError and take the LiveView down.
      result = render_click(live, "unarchive", %{"id" => [to_string(target.id)]})

      assert result =~ "Target not found"
      assert result =~ "Untouched"
      refute is_nil(Repo.get!(DeliveryTarget, target.id).archived_at)
    end

    test "an id with a trailing suffix is refused, not truncated to its numeric prefix", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      board = board_fixture(user)
      column = column_fixture(board)
      target = visible_archived_target(scope, user, column, %{name: "Not Truncated"})

      {:ok, live, _html} = live(conn, ~p"/targets/archived")

      # Integer.parse("12abc") returns {12, "abc"}, so a clause matching {n, _}
      # instead of {n, ""} would silently unarchive target 12. The remainder must
      # be empty for the id to be trusted.
      result = render_click(live, "unarchive", %{"id" => "#{target.id}abc"})

      assert result =~ "Target not found"
      refute is_nil(Repo.get!(DeliveryTarget, target.id).archived_at)
    end

    test "unarchiving a concurrently deleted target flashes an error without crashing",
         %{conn: conn, user: user, scope: scope} do
      board = board_fixture(user)
      column = column_fixture(board)
      target = visible_archived_target(scope, user, column, %{name: "Vanishing"})

      {:ok, live, _html} = live(conn, ~p"/targets/archived")

      # tasks.target_id is ON DELETE nilify_all, so the member goal survives.
      DeliveryTarget |> Repo.get!(target.id) |> Repo.delete!()

      result = render_click(live, "unarchive", %{"id" => to_string(target.id)})

      assert result =~ "Target not found"

      # The error branch deliberately does not re-read the list (mirroring
      # ArchiveLive.Index, and per the criterion that a refused target stays
      # listed), so the row for the now-deleted target remains until the next
      # mount. Harmless: clicking it again just re-flashes the same error.
      assert result =~ "Vanishing"
      refute has_element?(live, "[data-archived-targets-empty]")
    end
  end

  describe "row navigation" do
    setup [:register_and_log_in_user]

    test "each archived row links to that target's detail page", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      board = board_fixture(user)
      column = column_fixture(board)
      target = visible_archived_target(scope, user, column, %{name: "Shipped Q1"})

      {:ok, live, _html} = live(conn, ~p"/targets/archived")

      assert has_element?(
               live,
               "[data-archived-target-row][data-target-id='#{target.id}'] " <>
                 "[data-archived-target-link][href='#{~p"/targets/#{target}"}']"
             )
    end

    test "clicking an archived row navigates to that target's detail page", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      board = board_fixture(user)
      column = column_fixture(board)
      target = visible_archived_target(scope, user, column, %{name: "Shipped Q1"})

      {:ok, live, _html} = live(conn, ~p"/targets/archived")

      # <.link navigate> is a live redirect, so render_click returns the redirect
      # tuple rather than markup; follow_redirect drives it and proves the detail
      # page actually mounts at the expected path.
      assert {:ok, _show_live, html} =
               live
               |> element("[data-target-id='#{target.id}'] [data-archived-target-link]")
               |> render_click()
               |> follow_redirect(conn, ~p"/targets/#{target}")

      assert html =~ "Shipped Q1"
      assert html =~ "Member Goal"
    end

    test "the Unarchive button is a sibling of the row link, never nested inside it", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      board = board_fixture(user)
      column = column_fixture(board)
      visible_archived_target(scope, user, column)

      {:ok, live, _html} = live(conn, ~p"/targets/archived")

      # A button inside the anchor would be invalid markup AND would navigate
      # instead of unarchiving — the click would never reach phx-click.
      refute has_element?(live, "[data-archived-target-link] [data-unarchive-target]")
      assert has_element?(live, "[data-archived-target-row] > [data-unarchive-target]")
    end

    test "a board-visible but not-owned row still links, and following it lands on not-found",
         %{conn: conn, user: user, scope: scope} do
      other_user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      # THE SAME ASYMMETRY the Unarchive button carries: the listing is
      # board-scoped, the detail page is owner-scoped. The row links regardless
      # and the server refuses on arrival — by design, not a bug to filter away.
      target = visible_archived_target(scope, other_user, column, %{name: "Not Mine"})

      {:ok, live, _html} = live(conn, ~p"/targets/archived")

      assert has_element?(
               live,
               "[data-target-id='#{target.id}'] " <>
                 "[data-archived-target-link][href='#{~p"/targets/#{target}"}']"
             )

      assert {:error, {:live_redirect, %{to: path}}} =
               live
               |> element("[data-target-id='#{target.id}'] [data-archived-target-link]")
               |> render_click()

      assert path == ~p"/targets/#{target}"

      # Arriving there is refused server-side by the owner-scoped loader, so the
      # link is an affordance only — it never widens what the caller may read.
      assert {:error, {:live_redirect, %{to: refused_to, flash: flash}}} = live(conn, path)
      assert refused_to == ~p"/boards"
      assert flash["error"] =~ "Target not found"
    end
  end
end
