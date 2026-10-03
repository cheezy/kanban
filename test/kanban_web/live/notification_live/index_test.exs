defmodule KanbanWeb.NotificationLive.IndexTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.NotificationsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Columns
  alias Kanban.Notifications
  alias Kanban.Notifications.Notification
  alias Kanban.Repo

  defp row(notification), do: "#notifications-#{notification.id}"

  defp row_ids(html) do
    ~r/id="notifications-(\d+)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, id] -> String.to_integer(id) end)
  end

  defp read_at(notification), do: Repo.get!(Notification, notification.id).read_at

  test "unauthenticated access redirects to the log-in page" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/notifications")
  end

  describe "listing" do
    setup :register_and_log_in_user

    test "lists the user's notifications newest first and not other users'",
         %{conn: conn, user: user} do
      older = notification_fixture(user, %{title: "Older one"})
      newer = notification_fixture(user, %{title: "Newer one"})
      other = notification_fixture(user_fixture(), %{title: "Someone else's"})

      {:ok, view, _html} = live(conn, ~p"/notifications")

      assert has_element?(view, "#app-shell [data-notifications-screen]")
      assert row_ids(render(view)) == [newer.id, older.id]
      refute has_element?(view, row(other))
      assert has_element?(view, row(newer), "Board access changes")
    end

    test "renders the actor and body", %{conn: conn, user: user} do
      {:ok, [notification]} =
        Notifications.notify(:board_access_changed, [user], %{
          title: "Plain",
          body: "Line one\nLine two",
          actor_name: "Ada"
        })

      {:ok, view, _html} = live(conn, ~p"/notifications")

      assert has_element?(view, row(notification), "By Ada")
      assert has_element?(view, row(notification), "Line one")
    end

    test "renders the after_goal failure detail", %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)

      {:ok, [notification]} =
        Notifications.notify(:after_goal_failed, [user], %{
          title: "G1: after_goal failed",
          board_id: board.id,
          metadata: %{"exit_code" => 3, "duration_ms" => 1200}
        })

      {:ok, view, _html} = live(conn, ~p"/notifications")

      assert has_element?(view, row(notification), "Exit code 3 after 1200 ms")
    end

    test "shows a per-filter empty state", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/notifications")
      assert has_element?(view, "#notifications-empty", "No notifications yet.")

      notification = notification_fixture(user)
      scope = Scope.for_user(user)
      {:ok, _} = Notifications.mark_read(scope, notification.id)

      {:ok, view, _html} = live(conn, ~p"/notifications?filter=unread")
      assert has_element?(view, "#notifications-empty", "No unread notifications.")
    end

    test "the Unread filter hides read notifications", %{conn: conn, user: user, scope: scope} do
      read = notification_fixture(user)
      unread = notification_fixture(user)
      {:ok, _} = Notifications.mark_read(scope, read.id)

      {:ok, view, _html} = live(conn, ~p"/notifications")
      assert has_element?(view, row(read))

      view |> element(~s(a[data-filter="unread"])) |> render_click()
      assert_patch(view, ~p"/notifications?filter=unread")

      assert has_element?(view, row(unread))
      refute has_element?(view, row(read))
      assert has_element?(view, ~s(a[data-filter="unread"][aria-current="page"]))
    end

    test "load more pages through older notifications", %{conn: conn, user: user} do
      for _ <- 1..30, do: notification_fixture(user)

      {:ok, view, html} = live(conn, ~p"/notifications")
      assert length(row_ids(html)) == 25
      assert has_element?(view, "#notifications-load-more")

      html = view |> element("#notifications-load-more") |> render_click()

      assert length(row_ids(html)) == 30
      refute has_element?(view, "#notifications-load-more")
    end

    test "load more on an empty inbox changes nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/notifications")

      render_click(view, "load_more", %{})

      assert has_element?(view, "#notifications-empty", "No notifications yet.")
      refute has_element?(view, "#notifications-load-more")
    end

    test "a new notification is inserted at the top live", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/notifications")
      assert has_element?(view, "#notifications-empty")

      first = notification_fixture(user)
      second = notification_fixture(user)

      html = render(view)
      assert row_ids(html) == [second.id, first.id]
      refute has_element?(view, "#notifications-empty")
      assert has_element?(view, "#notification-bell-badge", "2")
    end

    test "a notification whose task was deleted disappears without breaking the page",
         %{conn: conn, user: user} do
      board = ai_optimized_board_fixture(user)
      column = board |> Columns.list_columns() |> hd()
      task = task_fixture(column)

      {:ok, [notification]} =
        Notifications.notify(:task_assigned, [user], %{
          title: "W1: gone soon",
          board_id: board.id,
          task_id: task.id,
          url_path: "/boards/#{board.id}/tasks/#{task.id}/edit"
        })

      kept = notification_fixture(user)
      Repo.delete!(task)

      {:ok, view, _html} = live(conn, ~p"/notifications")

      refute has_element?(view, row(notification))
      assert has_element?(view, row(kept))
    end
  end

  describe "reading" do
    setup :register_and_log_in_user

    test "clicking a notification marks it read and navigates to its url_path",
         %{conn: conn, user: user} do
      notification = notification_fixture(user, %{url_path: "/boards"})
      {:ok, view, _html} = live(conn, ~p"/notifications")

      view |> element("#{row(notification)} [data-notification-open]") |> render_click()

      assert_redirect(view, "/boards")
      assert read_at(notification)
    end

    test "a notification without a url_path is marked read in place",
         %{conn: conn, user: user} do
      notification = notification_fixture(user, %{url_path: nil})
      {:ok, view, _html} = live(conn, ~p"/notifications")

      view |> element("#{row(notification)} [data-notification-open]") |> render_click()

      assert read_at(notification)
      assert has_element?(view, ~s(#{row(notification)}[data-unread="false"]))
    end

    test "Mark as read updates the row and the badge", %{conn: conn, user: user} do
      notification = notification_fixture(user)
      notification_fixture(user)
      {:ok, view, _html} = live(conn, ~p"/notifications")

      view |> element("#{row(notification)} [data-notification-mark-read]") |> render_click()

      assert has_element?(view, ~s(#{row(notification)}[data-unread="false"]))
      refute has_element?(view, "#{row(notification)} [data-notification-mark-read]")
      assert has_element?(view, "#notification-bell-badge", "1")
      assert read_at(notification)
    end

    test "mark_read with another user's id leaves it unchanged", %{conn: conn} do
      other = notification_fixture(user_fixture())
      {:ok, view, _html} = live(conn, ~p"/notifications")

      html = render_click(view, "mark_read", %{"id" => to_string(other.id)})
      assert html =~ "Notification not found."
      assert render_click(view, "open", %{"id" => "abc"}) =~ "Notification not found."

      refute read_at(other)
    end

    test "Mark all read zeroes the badge and empties the Unread filter",
         %{conn: conn, user: user} do
      for _ <- 1..3, do: notification_fixture(user)
      {:ok, view, _html} = live(conn, ~p"/notifications?filter=unread")

      view |> element("#mark-all-read") |> render_click()

      refute has_element?(view, "#notification-bell-badge")
      assert has_element?(view, "#notifications-empty", "No unread notifications.")
      assert has_element?(view, "#mark-all-read[disabled]")
    end

    test "marking read in another tab refreshes the rows", %{conn: conn, user: user, scope: scope} do
      notification = notification_fixture(user)
      {:ok, view, _html} = live(conn, ~p"/notifications")

      {:ok, _} = Notifications.mark_read(scope, notification.id)

      assert has_element?(view, ~s(#{row(notification)}[data-unread="false"]))
      refute has_element?(view, "#notification-bell-badge")
    end

    test "ignores unrelated messages", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/notifications")

      send(view.pid, :noise)

      assert render(view) =~ "No notifications yet."
    end
  end

  test "renders translated text", %{conn: conn} do
    user = user_fixture()

    conn =
      conn
      |> log_in_user(user)
      |> Plug.Conn.put_session(:locale, "de")

    {:ok, _view, html} = live(conn, ~p"/notifications")

    assert html =~ "Benachrichtigungen"
    assert html =~ "Alle als gelesen markieren"
  end
end
