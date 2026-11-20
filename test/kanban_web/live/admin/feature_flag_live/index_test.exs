defmodule KanbanWeb.Admin.FeatureFlagLive.IndexTest do
  # Not async: every view subscribes to the global feature_flags topic, so a
  # change broadcast by a concurrent test (Kanban.FeatureFlagsTest is async)
  # could refresh a view, or send a just-demoted admin away, mid-test.
  use KanbanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures

  alias Kanban.Accounts.User
  alias Kanban.AuditLog
  alias Kanban.FeatureFlags
  alias Kanban.Repo

  @flag :mobile_app_preview
  @path "/admin/feature-flags"

  # Every msgid this page can show, for the every-locale check.
  @page_msgids [
    "Feature flags",
    "Turn unreleased features on for chosen users or for everyone. A change applies the next time a page loads; no restart is needed.",
    "Mobile app preview",
    "Shows the screens that matter only once the phone apps ship: the device list in account settings, the push notification settings, and the Organization policy that hides task titles in pushes.",
    "Off",
    "On for everyone",
    "Turn on for everyone",
    "Turn off for everyone",
    "Users with their own gate keep it when this is turned off for everyone.",
    "Turn %{flag} on for everyone? Every user, and every visitor who is not signed in, gets it at once.",
    "Turn %{flag} off for everyone? Users with their own gate keep it.",
    "Users with this flag",
    "No users have this flag.",
    "Active",
    "Deleted",
    "Deleted account (#%{id})",
    "Remove",
    "Email address",
    "Turn on for this user",
    "Turned on for that user.",
    "Turned off for that user.",
    "Turned on for everyone.",
    "Turned off for everyone.",
    "That user already has this flag.",
    "This flag is already on for everyone.",
    "This flag is already off for everyone.",
    "That user no longer has this flag.",
    "Enter an email address.",
    "No account uses that email address.",
    "That account is disabled, so it was not added.",
    "The change could not be saved. Please try again.",
    "Confirm the change first.",
    "Unknown feature flag."
  ]

  defp register_and_log_in_admin(%{conn: conn}) do
    admin = admin_fixture()
    %{conn: log_in_user(conn, admin), admin: admin}
  end

  defp events(action), do: AuditLog.list_events(action: action)

  defp add_user(view, email) do
    view
    |> form("#add-user-form-#{@flag}", %{"add_user" => %{"email" => email}})
    |> render_submit()
  end

  defp set_everyone(view, to) do
    view |> element("#everyone-#{@flag}") |> render_click()
    view |> element("#confirm-everyone-yes-#{@flag}") |> render_click()
    assert FeatureFlags.state(@flag) == if(to == :on, do: :everyone, else: :off)
  end

  describe "access control" do
    setup :register_and_log_in_user

    test "a non-admin is redirected away", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/", flash: flash}}} = live(conn, @path)
      assert flash["error"] =~ "admin"
    end

    test "an unauthenticated visitor is redirected to the login page" do
      conn = Phoenix.ConnTest.build_conn()

      assert {:error, {:redirect, %{to: redirect_to}}} = live(conn, @path)
      assert redirect_to == ~p"/users/log-in"
    end
  end

  describe "the page" do
    setup :register_and_log_in_admin

    test "lists every registered flag with its state", %{conn: conn} do
      user = user_fixture()
      :ok = FeatureFlags.enable_for_user(@flag, user)

      {:ok, view, _html} = live(conn, @path)

      for flag <- FeatureFlags.flags() do
        assert has_element?(view, "#flag-#{flag}")
        assert has_element?(view, "#flag-#{flag}-state")
      end

      assert has_element?(view, "#flag-#{@flag}-state", "On for 1 user")
      assert has_element?(view, "#flag-#{@flag}-user-#{user.id}", user.email)
    end

    test "a flag with no gates shows the translated empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#flag-#{@flag}-empty", "No users have this flag.")
      assert has_element?(view, "#flag-#{@flag}-state", "Off")
      refute has_element?(view, "#flag-#{@flag}-users")

      de_conn = Plug.Test.init_test_session(conn, %{"locale" => "de"})
      {:ok, de_view, _html} = live(de_conn, @path)

      empty =
        Gettext.with_locale(KanbanWeb.Gettext, "de", fn ->
          Gettext.gettext(KanbanWeb.Gettext, "No users have this flag.")
        end)

      refute empty == "No users have this flag."
      assert has_element?(de_view, "#flag-#{@flag}-empty", empty)
    end

    test "enabling a flag for a user by email adds them and records a feature_flag_enabled audit event",
         %{conn: conn, admin: admin} do
      user = user_fixture()
      {:ok, view, _html} = live(conn, @path)

      html = add_user(view, "  #{String.upcase(user.email)}  ")

      assert html =~ "Turned on for that user."
      assert has_element?(view, "#flag-#{@flag}-user-#{user.id}", user.email)
      assert has_element?(view, "#flag-#{@flag}-state", "On for 1 user")
      assert FeatureFlags.state(@flag) == {:users, [user.id]}

      assert [event] = events("feature_flag_enabled")
      assert event.actor_user_id == admin.id

      assert event.metadata == %{
               "user_id" => admin.id,
               "flag" => "mobile_app_preview",
               "target_user_id" => user.id,
               "scope" => "user"
             }

      refute inspect(event) =~ user.email
    end

    test "adding a user who already has the gate changes nothing", %{conn: conn} do
      user = user_fixture()
      {:ok, view, _html} = live(conn, @path)

      add_user(view, user.email)
      html = add_user(view, user.email)

      assert html =~ "That user already has this flag."
      assert length(events("feature_flag_enabled")) == 1
      assert FeatureFlags.state(@flag) == {:users, [user.id]}
    end

    test "an unknown email shows a translated error and changes nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert add_user(view, "nobody@example.invalid") =~ "No account uses that email address."
      assert add_user(view, "   ") =~ "Enter an email address."

      assert add_user(view, String.duplicate("a", 150) <> "@example.com") =~
               "Enter an email address."

      assert FeatureFlags.state(@flag) == :off
      assert events("feature_flag_enabled") == []

      de_conn = Plug.Test.init_test_session(conn, %{"locale" => "de"})
      {:ok, de_view, _html} = live(de_conn, @path)

      message =
        Gettext.with_locale(KanbanWeb.Gettext, "de", fn ->
          Gettext.gettext(KanbanWeb.Gettext, "No account uses that email address.")
        end)

      refute message == "No account uses that email address."
      assert add_user(de_view, "nobody@example.invalid") =~ message
    end

    test "a disabled account cannot be added, and one already gated shows as disabled",
         %{conn: conn} do
      disabled = user_fixture() |> disable!()
      {:ok, view, _html} = live(conn, @path)

      assert add_user(view, disabled.email) =~ "That account is disabled, so it was not added."
      assert FeatureFlags.state(@flag) == :off

      :ok = FeatureFlags.enable_for_user(@flag, disabled)
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#flag-#{@flag}-user-#{disabled.id} .badge-error", "Disabled")
      view |> element("#remove-#{@flag}-#{disabled.id}") |> render_click()
      assert FeatureFlags.state(@flag) == :off
    end

    test "removing a user turns the flag off for them and records feature_flag_disabled",
         %{conn: conn, admin: admin} do
      user = user_fixture()
      kept = user_fixture()
      :ok = FeatureFlags.enable_for_user(@flag, user)
      :ok = FeatureFlags.enable_for_user(@flag, kept)
      {:ok, view, _html} = live(conn, @path)

      html = view |> element("#remove-#{@flag}-#{user.id}") |> render_click()

      assert html =~ "Turned off for that user."
      refute has_element?(view, "#flag-#{@flag}-user-#{user.id}")
      assert FeatureFlags.state(@flag) == {:users, [kept.id]}

      assert [event] = events("feature_flag_disabled")
      assert event.actor_user_id == admin.id

      assert event.metadata == %{
               "user_id" => admin.id,
               "flag" => "mobile_app_preview",
               "target_user_id" => user.id,
               "scope" => "user"
             }
    end

    test "a deleted account's gate is listed and can be removed", %{conn: conn} do
      :ok = FeatureFlags.enable_for_user(@flag, %User{id: 999_999})
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#flag-#{@flag}-user-999999", "Deleted account (#999999)")
      assert has_element?(view, "#flag-#{@flag}-state", "On for 1 user")

      view |> element("#remove-#{@flag}-999999") |> render_click()

      assert FeatureFlags.state(@flag) == :off
      assert [%{metadata: %{"target_user_id" => 999_999}}] = events("feature_flag_disabled")
    end

    test "turn on for everyone needs confirmation and records feature_flag_enabled with scope everyone",
         %{conn: conn, admin: admin} do
      {:ok, view, _html} = live(conn, @path)

      # A pushed event with no confirm before it changes nothing.
      assert render_hook(view, "set_everyone", %{"flag" => "mobile_app_preview", "to" => "on"}) =~
               "Confirm the change first."

      assert FeatureFlags.state(@flag) == :off

      view |> element("#everyone-#{@flag}") |> render_click()
      assert has_element?(view, "#confirm-everyone-#{@flag}", "Every user")
      assert FeatureFlags.state(@flag) == :off

      view |> element("#confirm-everyone-cancel-#{@flag}") |> render_click()
      refute has_element?(view, "#confirm-everyone-#{@flag}")
      assert events("feature_flag_enabled") == []

      set_everyone(view, :on)

      assert has_element?(view, "#flag-#{@flag}-state", "On for everyone")
      refute has_element?(view, "#confirm-everyone-#{@flag}")

      assert [event] = events("feature_flag_enabled")
      assert event.actor_user_id == admin.id

      assert event.metadata == %{
               "user_id" => admin.id,
               "flag" => "mobile_app_preview",
               "scope" => "everyone"
             }
    end

    test "turn off for everyone keeps user gates and records scope everyone", %{conn: conn} do
      user = user_fixture()
      :ok = FeatureFlags.enable_for_user(@flag, user)
      :ok = FeatureFlags.enable_for_everyone(@flag)
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#flag-#{@flag}-everyone-note")
      view |> element("#everyone-#{@flag}") |> render_click()
      assert has_element?(view, "#confirm-everyone-#{@flag}", "keep it")
      view |> element("#confirm-everyone-yes-#{@flag}") |> render_click()

      assert FeatureFlags.state(@flag) == {:users, [user.id]}

      assert [%{metadata: %{"scope" => "everyone"} = metadata}] =
               events("feature_flag_disabled")

      refute Map.has_key?(metadata, "target_user_id")
    end

    test "an unknown flag or a malformed id is refused without a crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert render_hook(view, "remove_user", %{"flag" => "nope", "id" => "1"}) =~
               "Unknown feature flag."

      assert render_hook(view, "remove_user", %{"flag" => "mobile_app_preview", "id" => "x"}) =~
               "That user no longer has this flag."

      assert render_hook(view, "remove_user", %{
               "flag" => "mobile_app_preview",
               "id" => "99999999999999999999999"
             }) =~ "That user no longer has this flag."

      assert render_hook(view, "confirm_everyone", %{"flag" => "mobile_app_preview", "to" => "x"})
      refute has_element?(view, "#confirm-everyone-#{@flag}")
    end

    test "a malformed push is refused without a crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert render_hook(view, "add_user", %{}) =~ "Unknown feature flag."

      assert render_hook(view, "set_everyone", %{"flag" => "mobile_app_preview"}) =~
               "Unknown feature flag."

      assert render_hook(view, "add_user", %{"flag" => "mobile_app_preview", "add_user" => "x"}) =~
               "Enter an email address."

      assert render(view) =~ "Feature flags"
      assert AuditLog.list_events(action: "feature_flag_enabled") == []
    end

    test "a store that cannot be read refuses the change and keeps the page up", %{conn: conn} do
      user = user_fixture()
      {:ok, view, _html} = live(conn, @path)

      original = Application.get_env(:fun_with_flags, :persistence)
      on_exit(fn -> Application.put_env(:fun_with_flags, :persistence, original) end)

      Application.put_env(
        :fun_with_flags,
        :persistence,
        Keyword.put(original, :adapter, __MODULE__.UnreadableStore)
      )

      html =
        view
        |> form("#add-user-form-#{@flag}", add_user: %{email: user.email})
        |> render_submit()

      assert html =~ "The change could not be saved. Please try again."
      assert Process.alive?(view.pid)
      assert AuditLog.list_events(action: "feature_flag_enabled") == []
    end

    test "an admin demoted while the page is open can no longer toggle", %{
      conn: conn,
      admin: admin
    } do
      user = user_fixture()
      {:ok, view, _html} = live(conn, @path)

      admin |> Ecto.Changeset.change(type: :user) |> Repo.update!()

      assert add_user(view, user.email) =~ "You must be an admin to perform this action."
      assert FeatureFlags.state(@flag) == :off
      assert events("feature_flag_enabled") == []

      # Any later change sends the demoted admin away.
      :ok =
        admin_fixture()
        |> Kanban.Accounts.Scope.for_user()
        |> FeatureFlags.turn_on_for_everyone(@flag)

      assert_redirect(view, "/")
    end

    test "a demoted admin's malformed push reads no fresh gate data", %{conn: conn, admin: admin} do
      {:ok, view, _html} = live(conn, @path)
      admin |> Ecto.Changeset.change(type: :user) |> Repo.update!()

      # An unaudited change broadcasts nothing, so only a refresh could show it.
      user = user_fixture()
      :ok = FeatureFlags.enable_for_user(@flag, user)

      html = render_hook(view, "nope", %{})
      assert html =~ "Unknown feature flag."
      refute html =~ user.email
    end

    test "a refused address with an unreadable store keeps the page up", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      original = Application.get_env(:fun_with_flags, :persistence)
      on_exit(fn -> Application.put_env(:fun_with_flags, :persistence, original) end)

      Application.put_env(
        :fun_with_flags,
        :persistence,
        Keyword.put(original, :adapter, __MODULE__.UnreadableStore)
      )

      assert add_user(view, "nobody@example.invalid") =~ "No account uses that email address."
      assert Process.alive?(view.pid)
    end

    test "a toggle made in another session appears without a reload", %{conn: conn} do
      user = user_fixture()
      {:ok, view_a, _html} = live(conn, @path)
      {:ok, view_b, _html} = live(conn, @path)

      add_user(view_a, user.email)
      assert has_element?(view_b, "#flag-#{@flag}-user-#{user.id}", user.email)

      view_b |> element("#everyone-#{@flag}") |> render_click()
      set_everyone(view_a, :on)

      assert has_element?(view_b, "#flag-#{@flag}-state", "On for everyone")
      # B's pending turn-on confirm no longer applies.
      refute has_element?(view_b, "#confirm-everyone-#{@flag}")
    end

    test "a change on the page reaches the gated screens on their next load", %{conn: conn} do
      user = user_fixture()
      user_conn = log_in_user(Phoenix.ConnTest.build_conn(), user)

      {:ok, settings, _html} = live(user_conn, ~p"/users/settings")
      refute has_element?(settings, "#settings-tab-devices")

      {:ok, view, _html} = live(conn, @path)
      add_user(view, user.email)

      {:ok, settings, _html} = live(user_conn, ~p"/users/settings")
      assert has_element?(settings, "#settings-tab-devices")

      {:ok, notifications, _html} = live(user_conn, ~p"/users/notifications")
      assert has_element?(notifications, "#push-mode")

      view |> element("#remove-#{@flag}-#{user.id}") |> render_click()

      {:ok, settings, _html} = live(user_conn, ~p"/users/settings")
      refute has_element?(settings, "#settings-tab-devices")
    end
  end

  describe "locales" do
    setup :register_and_log_in_admin

    test "every string on the page has a translation in all seven locales", %{conn: conn} do
      bindings = [flag: "X", id: 1]

      for locale <- ~w(de es fr ja pt zh), msgid <- @page_msgids do
        [translated, english] =
          for l <- [locale, "en"] do
            Gettext.with_locale(KanbanWeb.Gettext, l, fn ->
              Gettext.gettext(KanbanWeb.Gettext, msgid, bindings)
            end)
          end

        refute translated == english, "#{locale} lacks a translation of #{inspect(msgid)}"
      end

      for locale <- ~w(de es fr ja pt zh) do
        Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
          one =
            Gettext.ngettext(
              KanbanWeb.Gettext,
              "On for %{count} user",
              "On for %{count} users",
              1
            )

          many =
            Gettext.ngettext(
              KanbanWeb.Gettext,
              "On for %{count} user",
              "On for %{count} users",
              2
            )

          refute one == "On for 1 user", "#{locale} lacks the singular user count"
          refute many == "On for 2 users", "#{locale} lacks the plural user count"
        end)
      end

      # A fuzzy entry is ignored at runtime, so one left behind by a merge would
      # show the English text silently.
      for locale <- ~w(de en es fr ja pt zh) do
        po =
          File.cwd!()
          |> Path.join("priv/gettext/#{locale}/LC_MESSAGES/default.po")
          |> File.read!()

        refute po =~ ~r/^#,.*\bfuzzy\b/m, "#{locale} has a fuzzy entry"
      end

      for locale <- ~w(de en es fr ja pt zh) do
        locale_conn = Plug.Test.init_test_session(conn, %{"locale" => locale})
        {:ok, _view, html} = live(locale_conn, @path)

        for msgid <- ["Feature flags", "Mobile app preview", "No users have this flag."] do
          text =
            Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
              Gettext.gettext(KanbanWeb.Gettext, msgid)
            end)

          assert html =~ text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string(),
                 "#{locale}: #{msgid}"
        end
      end
    end
  end

  describe "the developer guide" do
    test "docs/feature-flags.md describes the page, its gates and its audit actions" do
      doc = File.cwd!() |> Path.join("docs/feature-flags.md") |> File.read!()

      for text <- [
            "/admin/feature-flags",
            "live_session :admin",
            "feature_flag_enabled",
            "feature_flag_disabled",
            "Turn on for everyone",
            "Remove",
            "user gate",
            "everyone gate"
          ] do
        assert doc =~ text, "docs/feature-flags.md does not mention #{text}"
      end
    end

    test "docs/feature-flags.md and AGENTS.md give the same steps for adding a flag" do
      doc = File.cwd!() |> Path.join("docs/feature-flags.md") |> File.read!()
      agents = File.cwd!() |> Path.join("AGENTS.md") |> File.read!()

      for step <- [
            "`@flags`",
            "`@type flag`",
            "`flag_label/1`",
            "`flag_description/1`",
            "`KanbanWeb.Admin.FeatureFlagLive.Index`",
            "`Kanban.FeatureFlags.enabled?(scope, flag)`",
            "`test/kanban/feature_flags_test.exs`",
            "both states"
          ] do
        assert doc =~ step, "docs/feature-flags.md does not name #{step}"
        assert agents =~ step, "AGENTS.md does not name #{step}"
      end

      assert agents =~ "`docs/feature-flags.md`"
    end
  end

  defmodule UnreadableStore do
    @moduledoc false
    # Every read fails, as a store that is down would.
    def all_flag_names, do: {:error, :store_down}
  end

  defp disable!(user) do
    user |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:second)) |> Repo.update!()
  end
end
