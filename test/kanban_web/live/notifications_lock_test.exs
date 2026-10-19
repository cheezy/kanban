defmodule KanbanWeb.NotificationsLockTest do
  @moduledoc """
  Notifications while paid plans are enforced, as a user sees them: a free
  user gets a locked bell and locked notification pages, an Organization
  member keeps the normal ones, and the inbox only lists paid-board rows.
  """
  # async: false - these tests switch the global :plans_enforced application
  # env on through Kanban.PlansHelpers.
  use KanbanWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.NotificationsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TelemetryHelpers
  import Kanban.WorkspacesFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Boards.Board
  alias Kanban.Notifications
  alias Kanban.Notifications.Notification
  alias Kanban.Notifications.Preference
  alias Kanban.Organizations
  alias Kanban.Repo
  alias KanbanWeb.NotificationsOnMount
  alias KanbanWeb.UnsubscribeToken
  alias Phoenix.LiveView.Socket

  @refused [:kanban, :plan, :feature_refused]

  defp member_fixture do
    user = user_fixture()
    organization = organization_fixture()
    organization_member_fixture(organization, user)
    %{user: user, organization: organization}
  end

  defp make_paid(%Board{id: id} = board, organization) do
    workspace = org_workspace_fixture(organization)

    {1, _} =
      Board |> where([b], b.id == ^id) |> Repo.update_all(set: [workspace_id: workspace.id])

    board
  end

  defp board_notification(user, board, title) do
    notification_fixture(user, %{event_type: :comment_added, board_id: board.id, title: title})
  end

  defp preference_rows(user) do
    Preference |> where([p], p.user_id == ^user.id) |> Repo.all()
  end

  defp ids(notifications), do: notifications |> Enum.map(& &1.id) |> Enum.sort()

  # Counts the Repo queries this test process runs while `fun` executes, and
  # returns {result, count}.
  defp count_queries(fun) do
    test_pid = self()
    ref = :counters.new(1, [])
    handler_id = "notifications-lock-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:kanban, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == test_pid, do: :counters.add(ref, 1, 1)
      end,
      nil
    )

    try do
      result = fun.()
      {result, :counters.get(ref, 1)}
    after
      :telemetry.detach(handler_id)
    end
  end

  describe "a free user under enforcement" do
    setup %{conn: conn} do
      user = user_fixture()
      notification_fixture(user)
      enforce_plans()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "sees a locked bell with no badge on LiveView pages", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/boards")

      assert has_element?(view, "#notification-bell[data-notification-bell-locked]")
      assert has_element?(view, "#notification-bell-lock")
      refute has_element?(view, "#notification-bell-badge")

      assert has_element?(
               view,
               ~s{#notification-bell[aria-label="Notifications (available to organizations)"]}
             )
    end

    test "sees a locked bell on controller pages", %{conn: conn} do
      html = conn |> get(~p"/about") |> html_response(200)

      assert html =~ "data-notification-bell-locked"
      assert html =~ ~s(id="notification-bell-lock")
      refute html =~ "notification-bell-badge"
    end

    test "gets no live badge when a notification arrives", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/boards")

      # Board-less notifications are still generated under enforcement, so
      # this broadcasts; a locked LiveView is not subscribed to it.
      notification_fixture(user)
      _ = render(view)

      refute has_element?(view, "#notification-bell-badge")
      assert has_element?(view, "#notification-bell-lock")
    end

    test "a connected LiveView is not subscribed to the user's notifications",
         %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/boards")

      refute Notifications.topic(user) in Registry.keys(Kanban.PubSub, view.pid)
    end

    test "gets the unlocked bell on the next mount after joining an Organization",
         %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/boards")
      assert has_element?(view, "#notification-bell-lock")

      organization_member_fixture(organization_fixture(), user)

      {:ok, view, _html} = live(conn, ~p"/boards")
      refute has_element?(view, "#notification-bell-lock")
      assert view |> element("#notification-bell-badge") |> render() =~ ~r/>\s*1\s*</
      assert Notifications.topic(user) in Registry.keys(Kanban.PubSub, view.pid)
    end

    test "/notifications shows the locked panel with Review queue and My Work links",
         %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/notifications")

      assert has_element?(view, "#notifications-locked [data-locked-feature]")

      assert has_element?(
               view,
               ~s(#notifications-locked a[data-locked-review-link][href="/review"])
             )

      assert has_element?(
               view,
               ~s(#notifications-locked a[data-locked-my-work-link][href="/my-work"])
             )

      assert html =~ "Tasks waiting for you are always listed in the Review queue and My Work."
      refute has_element?(view, "#notifications")
      refute has_element?(view, "[phx-click=mark_all_read]")
    end

    test "/notifications ignores crafted events", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/notifications")
      [row] = Notification |> where([n], n.user_id == ^user.id) |> Repo.all()

      for {event, params} <- [
            {"mark_read", %{"id" => to_string(row.id)}},
            {"open", %{"id" => to_string(row.id)}},
            {"mark_all_read", %{}},
            {"load_more", %{}}
          ] do
        render_hook(view, event, params)
      end

      assert Repo.get!(Notification, row.id).read_at == nil
      assert has_element?(view, "#notifications-locked")
    end

    test "/users/notifications shows the locked panel and no settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/notifications")

      assert has_element?(view, "#notification-preferences-locked [data-locked-feature]")
      assert has_element?(view, "#notification-preferences-locked a[data-locked-review-link]")
      refute has_element?(view, "#pref-row-review_requested")
      refute has_element?(view, "#pref-weekly_digest-email")
    end

    test "a crafted save is refused with a flash and writes no preference",
         %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/users/notifications")

      html =
        render_hook(view, "save", %{"event_type" => "review_requested", "email" => "false"})

      assert html =~ "Notification settings are available to organizations."
      assert preference_rows(user) == []
    end
  end

  describe "an Organization member under enforcement" do
    setup %{conn: conn} do
      %{user: user} = member_fixture()
      notification_fixture(user)
      enforce_plans()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "sees the normal bell with the unread badge", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/boards")

      refute has_element?(view, "#notification-bell[data-notification-bell-locked]")
      refute has_element?(view, "#notification-bell-lock")
      assert view |> element("#notification-bell-badge") |> render() =~ ~r/>\s*1\s*</
    end

    test "sees the inbox and the settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/notifications")
      assert has_element?(view, "#notifications")
      refute has_element?(view, "#notifications-locked")

      {:ok, view, _html} = live(conn, ~p"/users/notifications")
      assert has_element?(view, "#pref-row-review_requested")
      refute has_element?(view, "#notification-preferences-locked")
    end
  end

  describe "with enforcement off" do
    setup %{conn: conn} do
      previous = Application.fetch_env(:kanban, :plans_enforced)
      on_exit(fn -> restore_plans_enforced(previous) end)
      Application.put_env(:kanban, :plans_enforced, false)
      user = user_fixture()
      notification_fixture(user)
      %{conn: log_in_user(conn, user), user: user}
    end

    test "a free user keeps the bell, the inbox and the settings", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/boards")
      refute has_element?(view, "#notification-bell-lock")
      assert view |> element("#notification-bell-badge") |> render() =~ ~r/>\s*1\s*</

      {:ok, view, _html} = live(conn, ~p"/notifications")
      refute has_element?(view, "#notifications-locked")

      {:ok, view, _html} = live(conn, ~p"/users/notifications")
      refute has_element?(view, "#notification-preferences-locked")

      assert {:ok, %Preference{email: false}} =
               user
               |> Scope.for_user()
               |> Notifications.update_preference(:review_requested, %{email: false})
    end
  end

  describe "update_preference/3" do
    test "refuses a free user under enforcement and emits feature_refused" do
      user = user_fixture()
      enforce_plans()
      attach_telemetry(@refused)

      assert {:error, {:plan_required, :notifications}} =
               user
               |> Scope.for_user()
               |> Notifications.update_preference(:review_requested, %{email: false})

      assert_received {:telemetry_event, @refused, %{count: 1},
                       %{feature: :notifications, surface: :context}}

      assert preference_rows(user) == []
    end

    test "allows an Organization member under enforcement" do
      %{user: user} = member_fixture()
      enforce_plans()

      scope =
        user
        |> Scope.for_user()
        |> Scope.put_organization_membership(Organizations.get_membership(user))

      assert {:ok, %Preference{email: false}} =
               Notifications.update_preference(scope, :review_requested, %{email: false})
    end
  end

  describe "unsubscribe for a free user under enforcement" do
    setup do
      user = user_fixture()
      enforce_plans()
      %{user: user}
    end

    test "the context call still turns email off", %{user: user} do
      assert :ok = Notifications.unsubscribe(user.id, :review_requested)
      assert [%Preference{event_type: :review_requested, email: false}] = preference_rows(user)
    end

    test "the signed link still turns email off", %{conn: conn, user: user} do
      token = UnsubscribeToken.sign(user.id, :review_requested)

      post(conn, ~p"/notifications/unsubscribe?#{[token: token]}")

      assert [%Preference{event_type: :review_requested, email: false}] = preference_rows(user)
    end
  end

  describe "the inbox under enforcement" do
    setup do
      %{user: user, organization: organization} = member_fixture()
      paid_board = user |> board_fixture() |> make_paid(organization)
      free_board = board_fixture(user)

      # Seeded before enforcement: notify generates nothing for a free board
      # once it is on.
      paid = board_notification(user, paid_board, "Paid board row")
      free = board_notification(user, free_board, "Free board row")
      board_less = notification_fixture(user, %{title: "Board-less row"})

      %{user: user, paid: paid, free: free, board_less: board_less}
    end

    test "lists and counts only paid-board and board-less rows", ctx do
      enforce_plans()
      scope = Scope.for_user(ctx.user)

      assert ids(Notifications.list_notifications(scope)) == ids([ctx.paid, ctx.board_less])
      assert Notifications.unread_count(scope) == 2
      assert {:error, :not_found} = Notifications.mark_read(scope, ctx.free.id)
      assert {:ok, 2} = Notifications.mark_all_read(scope)
      assert Repo.get!(Notification, ctx.free.id).read_at == nil
    end

    test "shows every row with enforcement off", ctx do
      scope = Scope.for_user(ctx.user)

      assert ids(Notifications.list_notifications(scope)) ==
               ids([ctx.paid, ctx.free, ctx.board_less])

      assert Notifications.unread_count(scope) == 3
    end

    test "the /notifications page hides free-board rows", %{conn: conn} = ctx do
      enforce_plans()
      {:ok, view, _html} = conn |> log_in_user(ctx.user) |> live(~p"/notifications")

      assert has_element?(view, "#notifications-#{ctx.paid.id}")
      assert has_element?(view, "#notifications-#{ctx.board_less.id}")
      refute has_element?(view, "#notifications-#{ctx.free.id}")
      assert view |> element("#notification-bell-badge") |> render() =~ ~r/>\s*2\s*</
    end
  end

  test "a paid user whose boards are all free has only board-less rows" do
    %{user: user} = member_fixture()
    free_board = board_fixture(user)
    board_notification(user, free_board, "Free board row")
    enforce_plans()

    scope = Scope.for_user(user)

    assert Notifications.list_notifications(scope) == []
    assert Notifications.unread_count(scope) == 0
  end

  describe "the lock is computed with the scope" do
    test "a locked scope mounts without a query or a count" do
      scope = %{Scope.for_user(user_fixture()) | notifications_locked: true}
      socket = %Socket{assigns: %{__changed__: %{}, current_scope: scope}}

      assert {{:cont, ^socket}, 0} =
               count_queries(fn -> NotificationsOnMount.on_mount(:default, %{}, %{}, socket) end)
    end

    test "the bell renders a locked scope without a query" do
      scope = %{Scope.for_user(user_fixture()) | notifications_locked: true}

      assert {html, 0} =
               count_queries(fn ->
                 render_component(&KanbanWeb.NotificationBell.bell/1, current_scope: scope)
               end)

      assert html =~ "notification-bell-lock"
    end
  end
end
