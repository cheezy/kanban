defmodule KanbanWeb.NotificationsOnMountTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.NotificationsFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Notifications
  alias KanbanWeb.NotificationsOnMount
  alias Phoenix.LiveView.Socket

  defp badge(view), do: view |> element("#notification-bell-badge") |> render()

  defp scope_socket(scope, extra \\ %{}) do
    %Socket{assigns: Map.merge(%{__changed__: %{}, current_scope: scope}, extra)}
  end

  describe "in authenticated LiveViews" do
    setup :register_and_log_in_user

    test "the badge equals the user's unread count", %{conn: conn, user: user} do
      for _ <- 1..3, do: notification_fixture(user)
      notification_fixture(user_fixture())

      {:ok, view, _html} = live(conn, ~p"/boards")

      assert badge(view) =~ ~r/>\s*3\s*</
      assert has_element?(view, ~s(#notification-bell[aria-label="3 unread notifications"]))
    end

    test "a new notification increments the badge without a reload", %{conn: conn, user: user} do
      notification_fixture(user)
      {:ok, view, _html} = live(conn, ~p"/boards")

      notification_fixture(user)

      assert badge(view) =~ ~r/>\s*2\s*</
    end

    test "many notifications arriving quickly are all counted", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/boards")
      refute has_element?(view, "#notification-bell-badge")

      for _ <- 1..5, do: notification_fixture(user)

      assert badge(view) =~ ~r/>\s*5\s*</
    end

    test "marking read elsewhere decrements the badge and mark-all-read clears it",
         %{conn: conn, user: user, scope: scope} do
      first = notification_fixture(user)
      notification_fixture(user)
      {:ok, view, _html} = live(conn, ~p"/boards")

      {:ok, _} = Notifications.mark_read(scope, first.id)
      assert badge(view) =~ ~r/>\s*1\s*</

      {:ok, _} = Notifications.mark_all_read(scope)
      refute has_element?(view, "#notification-bell-badge")
    end

    test "the bell renders on sudo-mode pages", %{conn: conn, user: user} do
      notification_fixture(user)

      {:ok, view, _html} = live(conn, ~p"/users/settings")

      assert badge(view) =~ ~r/>\s*1\s*</
    end

    test "the bell is live on the public app shell for signed-in users",
         %{conn: conn, user: user} do
      notification_fixture(user)

      {:ok, view, _html} = live(conn, ~p"/resources")

      assert badge(view) =~ ~r/>\s*1\s*</
    end

    test "controller-rendered pages show the bell with no badge", %{conn: conn, user: user} do
      notification_fixture(user)

      html = conn |> get(~p"/about") |> html_response(200)

      assert html =~ ~s(id="notification-bell")
      refute html =~ "notification-bell-badge"
    end
  end

  test "the bell renders on admin pages", %{conn: conn} do
    admin = admin_fixture()
    notification_fixture(admin)

    {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/admin/messages")

    assert badge(view) =~ ~r/>\s*1\s*</
  end

  describe "on_mount/4" do
    test "assigns the unread count into current_scope" do
      user = user_fixture()
      notification_fixture(user)
      notification_fixture(user)
      socket = user |> Scope.for_user() |> scope_socket()

      assert {:cont, socket} = NotificationsOnMount.on_mount(:default, %{}, %{}, socket)
      assert socket.assigns.current_scope.unread_notifications == 2
    end

    test "does nothing without a signed-in user" do
      socket = scope_socket(nil)

      assert {:cont, ^socket} = NotificationsOnMount.on_mount(:default, %{}, %{}, socket)
    end
  end

  describe "handle_message/2" do
    setup do
      scope = %{Scope.for_user(user_fixture()) | unread_notifications: 2}
      %{scope: scope}
    end

    test "halts notification messages after updating the count", %{scope: scope} do
      socket = scope_socket(scope)

      assert {:halt, created} =
               NotificationsOnMount.handle_message({:notification_created, %{}}, socket)

      assert created.assigns.current_scope.unread_notifications == 3

      assert {:halt, read} = NotificationsOnMount.handle_message({:notifications_read, 0}, socket)
      assert read.assigns.current_scope.unread_notifications == 0
    end

    test "passes notification messages on to the inbox", %{scope: scope} do
      socket = scope_socket(scope, %{notification_inbox?: true})

      assert {:cont, _socket} =
               NotificationsOnMount.handle_message({:notification_created, %{}}, socket)

      assert {:cont, _socket} =
               NotificationsOnMount.handle_message({:notifications_read, 1}, socket)
    end

    test "counts from one when the count was never loaded", %{scope: scope} do
      socket = scope_socket(%{scope | unread_notifications: nil})

      assert {:halt, socket} =
               NotificationsOnMount.handle_message({:notification_created, %{}}, socket)

      assert socket.assigns.current_scope.unread_notifications == 1
    end

    test "lets every other message through untouched", %{scope: scope} do
      socket = scope_socket(scope)

      assert {:cont, ^socket} = NotificationsOnMount.handle_message(:something_else, socket)

      assert {:cont, ^socket} =
               NotificationsOnMount.handle_message({:notifications_read, "x"}, socket)
    end
  end
end
