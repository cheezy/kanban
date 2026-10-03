defmodule KanbanWeb.UserLive.NotificationPreferencesTest do
  use KanbanWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Kanban.NotificationsFixtures

  alias Kanban.Notifications
  alias Kanban.Notifications.Preference
  alias Kanban.Repo
  alias KanbanWeb.UserLive.NotificationPreferences

  defp checked?(view, type, channel) do
    has_element?(view, "#pref-#{type}-#{channel}[checked]")
  end

  defp rows_for(user) do
    Preference
    |> where([p], p.user_id == ^user.id)
    |> Repo.all()
  end

  defp saved(scope, type) do
    scope
    |> Notifications.get_preferences()
    |> Enum.find(&(&1.event_type == type))
  end

  test "logged-out access redirects to the log-in page" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(build_conn(), ~p"/users/notifications")
  end

  describe "rendering" do
    setup :register_and_log_in_user

    test "shows the documented defaults for a user with no saved rows", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/users/notifications")

      assert html =~ "Notification preferences"
      assert checked?(view, :review_requested, "in_app")
      assert checked?(view, :review_requested, "email")
      # goal_completed and comment_added are in-app only by default
      assert checked?(view, :goal_completed, "in_app")
      refute checked?(view, :goal_completed, "email")
      refute checked?(view, :comment_added, "email")
      assert has_element?(view, "#pref-weekly_digest-email[checked]")
    end

    test "renders one row per user-facing type and none for weekly_digest", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/notifications")

      for type <- Notifications.event_types() -- [:weekly_digest] do
        assert has_element?(view, "#pref-row-#{type}"), "no row for #{type}"
      end

      refute has_element?(view, "#pref-row-weekly_digest")

      assert Enum.sort(NotificationPreferences.row_types() ++ [:weekly_digest]) ==
               Enum.sort(Notifications.event_types())
    end

    test "groups rows under readable headings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/notifications")

      assert has_element?(view, "#group-reviews #pref-row-task_reviewed")
      assert has_element?(view, "#group-tasks #pref-row-task_unclaimed")
      assert has_element?(view, "#group-goals #pref-row-after_goal_failed")
      assert has_element?(view, "#group-goals #pref-row-target_status_changed")
      assert has_element?(view, "#group-account #pref-row-board_access_changed")

      for heading <- ["Reviews", "Tasks and agents", "Goals and targets", "Account"] do
        assert has_element?(view, "h2", heading)
      end
    end

    test "each toggle is described by its event's name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/notifications")

      for channel <- ["in_app", "email"] do
        assert has_element?(
                 view,
                 ~s(#pref-task_reviewed-#{channel}[aria-describedby="pref-task_reviewed-name"])
               )
      end

      assert has_element?(view, "#pref-task_reviewed-name", "Review results")
    end

    test "reflects saved preferences", %{conn: conn, user: user} do
      preference_fixture(user, :task_assigned, %{in_app: false, email: false})

      {:ok, view, _html} = live(conn, ~p"/users/notifications")

      refute checked?(view, :task_assigned, "in_app")
      refute checked?(view, :task_assigned, "email")
    end

    test "loads with a stale session, unlike the sudo-gated settings page", %{conn: conn} do
      user = Kanban.AccountsFixtures.user_fixture()
      now = DateTime.utc_now(:second)
      stale = DateTime.add(now, -30, :minute)
      conn = log_in_user(conn, user, token_authenticated_at: stale)

      assert {:ok, _view, _html} = live(conn, ~p"/users/notifications")
      assert {:error, {:redirect, _}} = live(conn, ~p"/users/settings")
    end
  end

  describe "saving" do
    setup :register_and_log_in_user

    test "toggling email for review_requested persists and survives a re-mount",
         %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/users/notifications")

      html =
        view
        |> element("#pref-review_requested")
        |> render_change(%{
          "event_type" => "review_requested",
          "in_app" => "true",
          "email" => "false"
        })

      assert html =~ "Notification preferences saved."
      assert %{in_app: true, email: false} = saved(scope, :review_requested)

      {:ok, view, _html} = live(conn, ~p"/users/notifications")
      refute checked?(view, :review_requested, "email")
      assert checked?(view, :review_requested, "in_app")
    end

    test "turning both channels off is allowed", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/users/notifications")

      view
      |> element("#pref-task_unclaimed")
      |> render_change(%{
        "event_type" => "task_unclaimed",
        "in_app" => "false",
        "email" => "false"
      })

      assert %{in_app: false, email: false} = saved(scope, :task_unclaimed)
    end

    test "toggling the digest off stores weekly_digest email as false",
         %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/users/notifications")

      view
      |> element("#pref-weekly_digest")
      |> render_change(%{"email" => "false"})

      assert %{email: false, in_app: true} = saved(scope, :weekly_digest)
      refute has_element?(view, "#pref-weekly_digest-email[checked]")
    end

    test "a forged or unknown event type is rejected without creating rows",
         %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/users/notifications")

      html = render_change(view, "save", %{"event_type" => "bogus", "email" => "true"})
      assert html =~ "Unknown notification type."

      # the digest has its own toggle, so the row handler refuses it too
      render_change(view, "save", %{"event_type" => "weekly_digest", "email" => "false"})
      render_change(view, "save", %{"email" => "false"})

      assert rows_for(user) == []
    end

    test "an invalid flag value is reported, not saved", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/users/notifications")

      html =
        render_change(view, "save", %{"event_type" => "task_assigned", "email" => "maybe"})

      assert html =~ "Could not save that preference."
      assert rows_for(user) == []
    end

    test "never writes another user's preferences", %{conn: conn} do
      other = Kanban.AccountsFixtures.user_fixture()
      {:ok, view, _html} = live(conn, ~p"/users/notifications")

      render_change(view, "save", %{
        "event_type" => "task_assigned",
        "email" => "false",
        "user_id" => to_string(other.id)
      })

      assert rows_for(other) == []
    end

    test "two tabs editing at once: last write wins", %{conn: conn, scope: scope} do
      {:ok, first, _} = live(conn, ~p"/users/notifications")
      {:ok, second, _} = live(conn, ~p"/users/notifications")

      render_change(first, "save", %{
        "event_type" => "goal_completed",
        "in_app" => "true",
        "email" => "true"
      })

      render_change(second, "save", %{
        "event_type" => "goal_completed",
        "in_app" => "false",
        "email" => "false"
      })

      assert %{in_app: false, email: false} = saved(scope, :goal_completed)
    end
  end

  test "renders translated text", %{conn: conn} do
    user = Kanban.AccountsFixtures.user_fixture()

    conn =
      conn
      |> log_in_user(user)
      |> Plug.Conn.put_session(:locale, "de")

    {:ok, _view, html} = live(conn, ~p"/users/notifications")

    refute html =~ "Notification preferences"
    refute html =~ "Tasks and agents"
  end
end
