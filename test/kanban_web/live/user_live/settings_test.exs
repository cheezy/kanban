defmodule KanbanWeb.UserLive.SettingsTest do
  use KanbanWeb.ConnCase, async: true

  import Kanban.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Kanban.Accounts

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
      assert html =~ "Manage your account profile and password"
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

    test "remains accessible for sessions older than the former sudo window", %{conn: conn} do
      # Sessions authenticated more than 10 minutes ago used to be
      # bounced back to the log-in screen via the `:require_sudo_mode`
      # gate. The gate has been removed — an authenticated session is
      # enough to view the settings page.
      token_authenticated_at = DateTime.utc_now(:second) |> DateTime.add(-11, :minute)

      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture(), token_authenticated_at: token_authenticated_at)
        |> live(~p"/users/settings")

      assert html =~ "Update profile"
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
