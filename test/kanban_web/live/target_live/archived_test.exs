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

  defp goal_fixture(column, attrs \\ %{}) do
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
end
