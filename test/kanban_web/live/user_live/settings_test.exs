defmodule KanbanWeb.UserLive.SettingsTest do
  use KanbanWeb.ConnCase, async: true

  import Kanban.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Kanban.Accounts
  alias Kanban.Accounts.TwoFactor

  describe "Settings page" do
    test "renders settings page — Profile is the default tab, Password swaps in on select",
         %{conn: conn} do
      {:ok, lv, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings")

      # Profile is the default-active tab; its submit button must appear.
      # Password is hidden until its tab is clicked.
      assert html =~ "Update profile"
      refute html =~ "Save password"

      html = render_click(lv, "select_section", %{"section" => "password"})
      assert html =~ "Save password"
      refute html =~ "Update profile"
    end

    test "renders the settings page header with title and subtitle", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings")

      assert html =~ "Settings"
      assert html =~ "Manage your profile, password and notifications"

      # W1387: the settings panel carries the data-settings-panel anchor that the
      # app.css mobile rule targets to raise inputs/buttons (form fields, the tab
      # nav, submit buttons) to a 44px touch target below md. Guard the anchor.
      assert html =~ "data-settings-panel"
    end

    test "renders the profile section on mount and the password section after selecting its tab",
         %{conn: conn} do
      {:ok, lv, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings")

      # The Profile tab is selected by default — only the profile card renders.
      assert html =~ ~s(id="profile")
      refute html =~ ~s(id="password")
      assert html =~ "var(--surface)"
      assert html =~ "var(--line)"

      # Selecting the Password tab swaps which card is in the DOM.
      html = render_click(lv, "select_section", %{"section" => "password"})

      assert html =~ ~s(id="password")
      refute html =~ ~s(id="profile")
    end

    test "links to the notification preferences page from the section nav", %{conn: conn} do
      {:ok, lv, _html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings")

      assert has_element?(lv, ~s(nav a#settings-notifications-link[href="/users/notifications"]))
      # the link leaves the page, so it is not one of the tablist's tabs
      refute has_element?(lv, ~s([role="tablist"] #settings-notifications-link))
      # below md the link takes its own row so the tabs keep their width
      assert has_element?(lv, ~s(#settings-notifications-link[class*="basis-full"]))
      assert has_element?(lv, ~s([role="tablist"] button[role="tab"]), "Profile")

      refute has_element?(lv, ~s(#settings-notifications-link[aria-current]))

      assert {:error, {:live_redirect, %{to: "/users/notifications"}}} =
               lv |> element("#settings-notifications-link") |> render_click()
    end

    test "opens the Password tab from ?section=password (the other settings pages link there)",
         %{conn: conn} do
      {:ok, lv, _html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings?section=password")

      assert has_element?(lv, "#password_form")
      refute has_element?(lv, "#email_form")
      assert has_element?(lv, ~s(button[role="tab"][aria-selected="true"]), "Password")
    end

    test "each tab's aria-controls names the panel shown for it, labelled by the tab", %{
      conn: conn
    } do
      conn = log_in_user(conn, user_fixture())

      for section <- ~w(profile password two_factor) do
        {:ok, lv, _html} = live(conn, ~p"/users/settings?section=#{section}")

        assert has_element?(
                 lv,
                 ~s(button#settings-tab-#{section}[aria-selected="true"][aria-controls="#{section}"])
               )

        assert has_element?(
                 lv,
                 ~s(section##{section}[role="tabpanel"][aria-labelledby="settings-tab-#{section}"])
               )
      end
    end

    test "ignores an unknown ?section and opens Profile", %{conn: conn} do
      {:ok, lv, _html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings?section=bogus")

      assert has_element?(lv, "#email_form")
      refute has_element?(lv, "#password_form")
    end

    test "preserves the hidden username field for password managers", %{conn: conn} do
      # Password-manager autofill needs the username field in the same form.
      # The hidden username field is now inside the Password card, which only
      # renders when its tab is selected — switch to it before asserting.
      {:ok, lv, _html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings")

      html = render_click(lv, "select_section", %{"section" => "password"})

      assert html =~ ~s(id="hidden_user_email")
      assert html =~ ~s(autocomplete="username")
    end

    test "redirects if user is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/users/settings")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end

    test "bounces a session older than the 10-minute sudo window to re-authenticate (D155)",
         %{conn: conn} do
      # Changing credentials requires a recently-authenticated session. A
      # session authenticated more than 10 minutes ago is redirected to the
      # log-in (re-auth) page — a borrowed/stale session cannot reach settings.
      token_authenticated_at = DateTime.utc_now(:second) |> DateTime.add(-11, :minute)

      assert {:error, redirect} =
               conn
               |> log_in_user(user_fixture(), token_authenticated_at: token_authenticated_at)
               |> live(~p"/users/settings")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must re-authenticate to access this page."} = flash
    end
  end

  describe "update email form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "updates the user email", %{conn: conn, user: user} do
      new_email = unique_user_email()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"email" => new_email}
        })
        |> render_submit()

      assert result =~ "A link to confirm your email"
      assert Accounts.get_user_by_email(user.email)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#email_form")
        |> render_change(%{
          "action" => "update_email",
          "user" => %{"email" => "with spaces"}
        })

      assert result =~ "Update profile"
      assert result =~ "must have the @ sign and no spaces"
    end

    test "saves a new name without changing the email", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"name" => "Ada Lovelace", "email" => user.email}
        })
        |> render_submit()

      assert result =~ "Profile updated"
      assert %{name: "Ada Lovelace"} = Accounts.get_user_by_email(user.email)
    end

    test "rejects a name with HTML metacharacters", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"name" => "<script>x", "email" => user.email}
        })
        |> render_submit()

      assert result =~ "cannot contain HTML metacharacters"
      assert %{name: original_name} = Accounts.get_user_by_email(user.email)
      assert original_name == user.name
    end
  end

  describe "update password form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    # The settings page is tabbed (W: settings-tabs) — Profile renders by
    # default, Password only when its sidebar tab is selected. Each password
    # test must select the Password tab first or #password_form is absent
    # from the DOM.
    defp select_password_tab(lv) do
      render_click(lv, "select_section", %{"section" => "password"})
      lv
    end

    test "a validate re-render echoes both typed passwords back into their inputs",
         %{conn: conn, user: user} do
      # Same regression as the reset-password page: with no `value` rendered,
      # LiveView's DOM patch (`fromEl.value = toEl.value` on every non-focused
      # input) cleared "New password" the moment the confirmation was typed.
      {:ok, lv, _html} = live(conn, ~p"/users/settings")
      lv = select_password_tab(lv)

      html =
        lv
        |> form("#password_form", %{
          "user" => %{
            "email" => user.email,
            "password" => "supersecret1234",
            "password_confirmation" => "sup"
          }
        })
        |> render_change()

      assert html =~ ~s(value="supersecret1234")
      assert html =~ ~s(value="sup")
    end

    test "updates the user password", %{conn: conn, user: user} do
      new_password = valid_user_password()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")
      lv = select_password_tab(lv)

      form =
        form(lv, "#password_form", %{
          "user" => %{
            "email" => user.email,
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      render_submit(form)

      new_password_conn = follow_trigger_action(form, conn)

      assert redirected_to(new_password_conn) == ~p"/users/settings"

      assert get_session(new_password_conn, :user_token) != get_session(conn, :user_token)

      assert Phoenix.Flash.get(new_password_conn.assigns.flash, :info) =~
               "Password updated successfully"

      assert Accounts.get_user_by_email_and_password(user.email, new_password)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")
      lv = select_password_tab(lv)

      result =
        lv
        |> element("#password_form")
        |> render_change(%{
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })

      assert result =~ "Save password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")
      lv = select_password_tab(lv)

      result =
        lv
        |> form("#password_form", %{
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })
        |> render_submit()

      assert result =~ "Save password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end
  end

  describe "two-factor section" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    # The code an authenticator would show `offset_steps` 30-second steps from now.
    defp totp(secret, offset_steps \\ 0) do
      NimbleTOTP.verification_code(secret, time: System.os_time(:second) + offset_steps * 30)
    end

    defp open_two_factor(conn) do
      {:ok, lv, _html} = live(conn, ~p"/users/settings?section=two_factor")
      lv
    end

    defp enroll(user) do
      {:ok, %{secret: secret}} = Accounts.begin_two_factor_enrollment(user)
      {:ok, codes} = Accounts.confirm_two_factor_enrollment(user, totp(secret))
      %{secret: secret, recovery_codes: codes}
    end

    test "is a tab on the settings page and opens off by default", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      assert has_element?(lv, ~s([role="tablist"] button[phx-value-section="two_factor"]))

      html = render_click(lv, "select_section", %{"section" => "two_factor"})

      assert html =~ "Two-factor authentication is off."
      assert has_element?(lv, "#two-factor-begin")
    end

    test "opens from a ?section=two_factor link", %{conn: conn} do
      lv = open_two_factor(conn)

      assert has_element?(lv, "#two_factor #two-factor-status")
    end

    test "enrolls with a valid code, shows the recovery codes once, then shows it on",
         %{conn: conn, user: user} do
      lv = open_two_factor(conn)

      lv |> element("#two-factor-begin") |> render_click()

      assert has_element?(lv, ~s(#two-factor-qr[src^="data:image/svg+xml;base64,"]))
      secret = TwoFactor.get_user_totp(user).secret
      key = lv |> element("#two-factor-key") |> render()
      assert key =~ secret |> Base.encode32(padding: false) |> String.slice(0, 4)
      refute Accounts.two_factor_enabled?(user)

      html =
        lv
        |> form("#two-factor-confirm-form", %{"code" => totp(secret)})
        |> render_submit()

      assert Accounts.two_factor_enabled?(user)
      assert html =~ "Save these recovery codes now"

      assert lv |> element("#two-factor-recovery-codes") |> render() =~
               ~r/[0-9a-z]{5}-[0-9a-z]{5}/

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#two-factor-recovery-codes li")
             |> Enum.count() == 10

      # the secret leaves the page once enrollment is confirmed
      refute has_element?(lv, "#two-factor-qr")
      refute has_element?(lv, "#two-factor-key")

      html = lv |> element("#two-factor-codes-saved") |> render_click()
      assert html =~ "Two-factor authentication is on."
      refute has_element?(lv, "#two-factor-recovery-codes")

      # a fresh visit never shows the codes again
      lv = open_two_factor(conn)
      assert has_element?(lv, "#two-factor-disable-form")
      refute has_element?(lv, "#two-factor-recovery-codes")
    end

    test "a wrong code during enrollment shows an error and keeps it off",
         %{conn: conn, user: user} do
      lv = open_two_factor(conn)
      lv |> element("#two-factor-begin") |> render_click()
      secret = TwoFactor.get_user_totp(user).secret
      wrong = if totp(secret) == "000000", do: "111111", else: "000000"

      html = lv |> form("#two-factor-confirm-form", %{"code" => wrong}) |> render_submit()

      assert html =~ "That code is not valid."
      assert has_element?(lv, ~s(#two-factor-confirm-code[aria-invalid="true"]))
      assert has_element?(lv, "#two-factor-qr")
      refute Accounts.two_factor_enabled?(user)
    end

    test "cancelling enrollment discards the pending secret", %{conn: conn, user: user} do
      lv = open_two_factor(conn)
      lv |> element("#two-factor-begin") |> render_click()

      lv |> element("#two-factor-cancel") |> render_click()

      assert has_element?(lv, "#two-factor-begin")
      assert TwoFactor.get_user_totp(user) == nil
    end

    test "disable with a wrong code shows an error and keeps two-factor on",
         %{conn: conn, user: user} do
      %{secret: secret} = enroll(user)
      lv = open_two_factor(conn)
      wrong = if totp(secret, 1) == "000000", do: "111111", else: "000000"

      html = lv |> form("#two-factor-disable-form", %{"code" => wrong}) |> render_submit()

      assert html =~ "That code is not valid."
      assert Accounts.two_factor_enabled?(user)
    end

    test "disable with a current code turns it off", %{conn: conn, user: user} do
      %{secret: secret} = enroll(user)
      lv = open_two_factor(conn)

      html =
        lv |> form("#two-factor-disable-form", %{"code" => totp(secret, 1)}) |> render_submit()

      assert html =~ "Two-factor authentication is off."
      assert has_element?(lv, "#two-factor-begin")
      refute Accounts.two_factor_enabled?(user)
    end

    test "disable with a recovery code turns it off", %{conn: conn, user: user} do
      %{recovery_codes: [recovery | _]} = enroll(user)
      lv = open_two_factor(conn)

      lv |> form("#two-factor-disable-form", %{"code" => recovery}) |> render_submit()

      assert has_element?(lv, "#two-factor-begin")
      refute Accounts.two_factor_enabled?(user)
    end

    test "regenerating with a current code shows ten new codes once", %{conn: conn, user: user} do
      %{secret: secret, recovery_codes: [old | _]} = enroll(user)
      lv = open_two_factor(conn)

      html =
        lv |> form("#two-factor-regenerate-form", %{"code" => totp(secret, 1)}) |> render_submit()

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#two-factor-recovery-codes li")
             |> Enum.count() == 10

      assert Accounts.consume_recovery_code(user, old) == {:error, :invalid_code}

      lv |> element("#two-factor-codes-saved") |> render_click()
      refute has_element?(lv, "#two-factor-recovery-codes")
    end

    test "regenerating with a wrong code shows an error", %{conn: conn, user: user} do
      %{secret: secret, recovery_codes: [old | _]} = enroll(user)
      lv = open_two_factor(conn)
      wrong = if totp(secret, 1) == "000000", do: "111111", else: "000000"

      html = lv |> form("#two-factor-regenerate-form", %{"code" => wrong}) |> render_submit()

      assert html =~ "That code is not valid."
      refute has_element?(lv, "#two-factor-recovery-codes")
      assert Accounts.consume_recovery_code(user, old) == :ok
    end
  end

  describe "confirm email" do
    setup %{conn: conn} do
      user = user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{conn: log_in_user(conn, user), token: token, email: email, user: user}
    end

    test "updates the user email once", %{conn: conn, user: user, token: token, email: email} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")

      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"info" => message} = flash
      assert message == "Email changed successfully."
      refute Accounts.get_user_by_email(user.email)
      assert Accounts.get_user_by_email(email)

      # use confirm token again
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
    end

    test "does not update email with invalid token", %{conn: conn, user: user} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/oops")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
      assert Accounts.get_user_by_email(user.email)
    end

    test "redirects if user is not logged in", %{token: token} do
      conn = build_conn()
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => message} = flash
      assert message == "You must log in to access this page."
    end
  end
end
