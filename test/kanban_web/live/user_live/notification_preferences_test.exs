defmodule KanbanWeb.UserLive.NotificationPreferencesTest do
  use KanbanWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Kanban.NotificationsFixtures

  alias Kanban.Notifications
  alias Kanban.Notifications.Preference
  alias Kanban.Notifications.PushSettings
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
      assert has_element?(view, "#group-board_access #pref-row-board_access_changed")
      assert has_element?(view, "#group-comments #pref-row-comment_added")
      assert has_element?(view, "#group-comments #pref-row-mentioned")
      refute has_element?(view, "#group-tasks #pref-row-comment_added")

      headings = [
        "Reviews",
        "Tasks and agents",
        "Goals and targets",
        "Board access",
        "Comments and mentions",
        "Weekly digest"
      ]

      for heading <- headings do
        assert has_element?(view, "h3", heading)
      end
    end

    test "orders the groups reviews, tasks, goals, board access, comments, digest",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/users/notifications")

      ids =
        ~r/id="group-([a-z_]+)"/
        |> Regex.scan(html, capture: :all_but_first)
        |> List.flatten()

      assert ids == ["reviews", "tasks", "goals", "board_access", "comments", "digest"]
    end

    test "renders inside the settings shell with Notifications as the current section",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/notifications")

      assert has_element?(view, "[data-settings-panel] h1", "Settings")
      assert has_element?(view, "[data-settings-panel] h2", "Notification preferences")

      assert has_element?(
               view,
               ~s(nav a#settings-notifications-link[aria-current="page"][href="/users/notifications"])
             )

      # Profile and Password are links back to the settings page, not tabs.
      assert has_element?(view, ~s(nav a#settings-profile-link[href="/users/settings"]))

      assert has_element?(
               view,
               ~s(nav a#settings-password-link[href="/users/settings?section=password"])
             )

      refute has_element?(view, ~s([role="tablist"]))
      refute has_element?(view, ~s(#settings-profile-link[aria-current]))
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

    test "toggle forms drop the checkbox spacing and keep a 44px phone tap height",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/notifications")

      for form <- ["#pref-task_assigned", "#pref-weekly_digest"] do
        assert has_element?(view, ~s(#{form}[class*="[&_.fieldset]:m-0"]))
        assert has_element?(view, ~s(#{form}[class*="[&_label]:min-h-11"]))
        # long labels (the weekly digest's) wrap instead of overflowing at 320px
        assert has_element?(view, ~s(#{form}[class*="[&_.label]:whitespace-normal"]))
      end
    end

    test "rows switch to one line by the settings column's width, not the viewport's",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/notifications")

      assert has_element?(view, ~s([data-settings-panel] [class*="@container"] #group-reviews))
      assert has_element?(view, ~s(#pref-row-task_assigned[class*="@md:flex-row"]))
      refute has_element?(view, ~s(#pref-row-task_assigned[class*="sm:flex-row"]))
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

  describe "push" do
    setup :register_and_log_in_user

    test "a person with no settings row sees the defaults", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/users/notifications")

      assert has_element?(view, ~s(#push-mode-select option[value="decisions"][selected]))

      for type <- PushSettings.decision_events() do
        assert checked?(view, type, "push"), "#{type} push should be on"
      end

      for type <- PushSettings.update_events() do
        assert has_element?(view, "#pref-#{type}-push")
        refute checked?(view, type, "push"), "#{type} push should be off"
      end

      refute has_element?(view, "#push-quiet_hours_enabled[checked]")
      assert has_element?(view, ~s(#push-quiet_start[value="22:00"]))
      assert has_element?(view, ~s(#push-quiet_end[value="07:00"]))
      # the test browser reports no zone, so the prompt is chosen
      refute has_element?(view, "#push-time_zone option[selected]")

      # loading the page writes nothing
      assert Repo.get(PushSettings, user.id) == nil
      assert rows_for(user) == []
    end

    test "toggles push for review_requested", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/users/notifications")

      html =
        view
        |> element("#push-review_requested")
        |> render_change(%{"event_type" => "review_requested", "push" => "false"})

      assert html =~ "Notification preferences saved."
      assert Notifications.get_push_settings(scope).switches.review_requested == false
      # in-app and email are untouched
      assert %{in_app: true, email: true} = saved(scope, :review_requested)
      # one switch does not change the mode
      assert Notifications.get_push_settings(scope).mode == :decisions

      {:ok, view, _html} = live(conn, ~p"/users/notifications")
      refute checked?(view, :review_requested, "push")
      assert checked?(view, :review_requested, "email")
    end

    test "never-push events show no push switch", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/notifications")

      for type <- PushSettings.never_push_events() -- [:weekly_digest] do
        refute has_element?(view, "#pref-#{type}-push"), "#{type} has a push switch"
        refute has_element?(view, "#push-#{type}")
        assert has_element?(view, "#pref-row-#{type} [data-push-none][aria-hidden=true]")
      end

      refute has_element?(view, "#pref-weekly_digest-push")

      for type <- PushSettings.push_events() do
        assert has_element?(
                 view,
                 ~s(#pref-#{type}-push[aria-describedby="pref-#{type}-name"])
               )
      end
    end

    test "a forged push for a never-push or unknown event is refused",
         %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/users/notifications")

      for type <- ["task_assigned", "weekly_digest", "bogus"] do
        html = render_hook(view, "save_push", %{"event_type" => type, "push" => "true"})
        assert html =~ "Unknown notification type."
      end

      assert Repo.get(PushSettings, user.id) == nil
      assert rows_for(user) == []
    end

    test "an invalid push value is reported, not saved", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/users/notifications")

      html =
        render_hook(view, "save_push", %{"event_type" => "mentioned", "push" => "maybe"})

      assert html =~ "Could not save that preference."
      assert Notifications.get_push_settings(scope).switches.mentioned == false
    end

    test "choosing Every event turns every push switch on", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/users/notifications")

      view
      |> element("#push-mode-form")
      |> render_change(%{"mode" => "every"})

      assert %{mode: :every, switches: switches} = Notifications.get_push_settings(scope)
      assert switches |> Map.values() |> Enum.all?()

      for type <- PushSettings.push_events() do
        assert checked?(view, type, "push")
      end

      assert has_element?(view, ~s(#push-mode-select option[value="every"][selected]))
    end

    test "an unknown mode is reported, not saved", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/users/notifications")

      html = render_hook(view, "save_push_mode", %{"mode" => "loud"})

      assert html =~ "Could not save that preference."
      assert Repo.get(PushSettings, user.id) == nil
    end

    test "saves quiet hours and time zone", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/users/notifications")

      html =
        view
        |> element("#push-quiet-hours-form")
        |> render_submit(%{
          "quiet_hours_enabled" => "true",
          "quiet_start" => "23:30",
          "quiet_end" => "06:15",
          "time_zone" => "Europe/Berlin"
        })

      assert html =~ "Notification preferences saved."

      assert %{
               quiet_hours_enabled: true,
               quiet_start: ~T[23:30:00],
               quiet_end: ~T[06:15:00],
               time_zone: "Europe/Berlin"
             } = Notifications.get_push_settings(scope)

      {:ok, view, _html} = live(conn, ~p"/users/notifications")
      assert has_element?(view, "#push-quiet_hours_enabled[checked]")
      assert has_element?(view, ~s(#push-quiet_start[value="23:30"]))
      assert has_element?(view, ~s(#push-quiet_end[value="06:15"]))
      assert has_element?(view, ~s(#push-time_zone option[value="Europe/Berlin"][selected]))
    end

    test "invalid quiet hours show an error", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/users/notifications")

      html =
        view
        |> element("#push-quiet-hours-form")
        |> render_submit(%{
          "quiet_hours_enabled" => "false",
          "quiet_start" => "09:00",
          "quiet_end" => "09:00",
          "time_zone" => "Europe/Berlin"
        })

      assert html =~ "Could not save that preference."
      assert html =~ "Quiet hours can&#39;t start and end at the same time."
      # the submitted values stay in the form
      assert has_element?(view, ~s(#push-quiet_end[value="09:00"]))
      assert Notifications.get_push_settings(scope).quiet_start == ~T[22:00:00]

      # turning quiet hours on needs a zone; the prompt sends a blank one
      html =
        view
        |> element("#push-quiet-hours-form")
        |> render_submit(%{
          "quiet_hours_enabled" => "true",
          "quiet_start" => "22:00",
          "quiet_end" => "07:00",
          "time_zone" => ""
        })

      assert html =~ "Choose a time zone to turn on quiet hours."
      refute Notifications.get_push_settings(scope).quiet_hours_enabled
    end

    test "a forged zone or time is reported against its field", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/users/notifications")

      html =
        render_hook(view, "save_quiet_hours", %{
          "quiet_start" => "25:99",
          "time_zone" => "Mars/Base"
        })

      assert html =~ "Choose a time zone from the list."
      assert html =~ "Enter a time, such as 22:00."
      assert Repo.get(PushSettings, user.id) == nil
    end

    test "a stored zone is kept when only the times change", %{conn: conn, scope: scope} do
      {:ok, _view} =
        Notifications.update_push_settings(scope, %{"time_zone" => "Asia/Kathmandu"},
          via: :web,
          feature: :notifications
        )

      {:ok, view, _html} = live(conn, ~p"/users/notifications")

      # a zone outside the curated list is still offered, and chosen
      assert has_element?(view, ~s(#push-time_zone option[value="Asia/Kathmandu"][selected]))

      render_hook(view, "save_quiet_hours", %{"quiet_start" => "21:00", "time_zone" => ""})

      assert %{quiet_start: ~T[21:00:00], time_zone: "Asia/Kathmandu"} =
               Notifications.get_push_settings(scope)
    end

    test "suggests the browser's zone when none is stored", %{conn: conn, user: user} do
      conn = put_connect_params(conn, %{"timezone" => "Asia/Tokyo"})
      {:ok, view, _html} = live(conn, ~p"/users/notifications")

      assert has_element?(view, ~s(#push-time_zone option[value="Asia/Tokyo"][selected]))
      assert Repo.get(PushSettings, user.id) == nil
    end

    test "a quiet hours form left open does not revert what the app changed",
         %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/users/notifications")

      # the app changes the end while the page still shows 07:00
      {:ok, _view} =
        Notifications.update_push_settings(scope, %{"quiet_end" => "08:30"},
          via: :ios,
          feature: :mobile_app
        )

      view
      |> element("#push-quiet-hours-form")
      |> render_submit(%{
        "quiet_hours_enabled" => "false",
        "quiet_start" => "22:00",
        "quiet_end" => "07:00",
        "time_zone" => "Europe/Berlin"
      })

      assert %{quiet_end: ~T[08:30:00], time_zone: "Europe/Berlin"} =
               Notifications.get_push_settings(scope)

      # and the page now shows what is stored
      assert has_element?(view, ~s(#push-quiet_end[value="08:30"]))
    end

    test "a refused quiet hours save does not let the next one revert the app's change",
         %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/users/notifications")

      {:ok, _view} =
        Notifications.update_push_settings(scope, %{"quiet_start" => "23:00"},
          via: :ios,
          feature: :mobile_app
        )

      html =
        render_hook(view, "save_quiet_hours", %{
          "quiet_hours_enabled" => "false",
          "quiet_start" => "22:00",
          "quiet_end" => "06:00",
          "time_zone" => "Mars/Base"
        })

      assert html =~ "Choose a time zone from the list."

      # the form still shows 22:00 as the start, which the person never touched
      view
      |> element("#push-quiet-hours-form")
      |> render_submit(%{
        "quiet_hours_enabled" => "false",
        "quiet_start" => "22:00",
        "quiet_end" => "06:00",
        "time_zone" => "Europe/Berlin"
      })

      assert %{quiet_start: ~T[23:00:00], quiet_end: ~T[06:00:00], time_zone: "Europe/Berlin"} =
               Notifications.get_push_settings(scope)
    end

    test "submitting quiet hours unchanged saves nothing new", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/users/notifications")

      html =
        view
        |> element("#push-quiet-hours-form")
        |> render_submit(%{
          "quiet_hours_enabled" => "false",
          "quiet_start" => "22:00",
          "quiet_end" => "07:00",
          "time_zone" => ""
        })

      assert html =~ "Notification preferences saved."
      assert Repo.get(PushSettings, user.id) == nil
    end

    test "choosing a mode the app already stored applies its preset",
         %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/users/notifications")

      # the app switches to every event and then turns one update off
      {:ok, _view} =
        Notifications.update_push_settings(
          scope,
          %{"mode" => "every", "switches" => %{"mentioned" => false}},
          via: :ios,
          feature: :mobile_app
        )

      # the stale page still shows Decisions only; choosing Every event turns all on
      view
      |> element("#push-mode-form")
      |> render_change(%{"mode" => "every"})

      assert %{mode: :every, switches: %{mentioned: true}} =
               Notifications.get_push_settings(scope)
    end

    test "an app change is reflected on the next load", %{conn: conn, scope: scope} do
      {:ok, _view} =
        Notifications.update_push_settings(scope, %{"switches" => %{"mentioned" => true}},
          via: :ios,
          feature: :mobile_app
        )

      # an app change is reflected on the next load
      {:ok, view, _html} = live(conn, ~p"/users/notifications")
      assert checked?(view, :mentioned, "push")
    end
  end

  test "the push controls let long German labels wrap", %{conn: conn} do
    user = Kanban.AccountsFixtures.user_fixture()

    conn =
      conn
      |> log_in_user(user)
      |> Plug.Conn.put_session(:locale, "de")

    {:ok, view, html} = live(conn, ~p"/users/notifications")
    assert html =~ "Ruhezeiten einschalten"

    for form <- ["#push-review_requested", "#push-mode-form"] do
      assert has_element?(view, ~s(#{form}[class*="[&_.label]:whitespace-normal"]))
    end

    # the quiet hours toggle and the start, end and zone grid
    assert has_element?(
             view,
             ~s(#push-quiet-hours-form > div[class*="[&_.label]:whitespace-normal"] #push-quiet_hours_enabled)
           )

    assert has_element?(
             view,
             ~s(#push-quiet-hours-form > div[class*="[&_.label]:whitespace-normal"] #push-time_zone)
           )
  end

  test "renders in German", %{conn: conn} do
    user = Kanban.AccountsFixtures.user_fixture()

    conn =
      conn
      |> log_in_user(user)
      |> Plug.Conn.put_session(:locale, "de")

    {:ok, _view, html} = live(conn, ~p"/users/notifications")

    assert html =~ "Ruhezeiten"
    assert html =~ "Nur Entscheidungen (empfohlen)"
    refute html =~ "Quiet hours"
    refute html =~ "Every event"
    refute html =~ "Notify me"
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
