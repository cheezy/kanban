defmodule KanbanWeb.UserLive.LoginTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures

  describe "login page" do
    test "renders login page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "Sign in"
      assert html =~ "Create an account"
      assert html =~ "Keep me signed in"
      assert html =~ "Forgot?"
    end

    test "renders inside the editorial auth_frame", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      # The auth_frame brand panel renders the rotating signin quote and
      # the warm gradient — both unique to the new design's 2-column shell.
      assert html =~ "Agents finally have somewhere good to work."
      assert html =~ "linear-gradient(155deg, oklch(96% 0.025 60)"
    end

    test "no blue Tailwind classes inside the login surface", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      # Scope to the <main> auth-frame column (the surrounding NavComponents
      # still has blue hover states — covered by W665 in the same goal).
      [_, main_and_after] = String.split(html, ~r/<main[^>]*>/, parts: 2)
      [main, _] = String.split(main_and_after, "</main>", parts: 2)

      refute main =~ ~r/(text|bg|from|to|border)-blue-\d+/
    end
  end

  describe "user login - password" do
    test "redirects if user logs in with valid credentials", %{conn: conn} do
      user = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form_password",
          user: %{email: user.email, password: valid_user_password(), remember_me: true}
        )

      conn = submit_form(form, conn)

      assert redirected_to(conn) == ~p"/boards"
    end

    test "redirects to login page with a flash error if credentials are invalid", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form_password", user: %{email: "test@email.com", password: "123456"})

      render_submit(form, %{user: %{remember_me: true}})

      conn = follow_trigger_action(form, conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "login navigation" do
    test "redirects to registration page when the Register button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Create an account")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/register")

      assert login_html =~ "Create your account"
    end
  end

  describe "re-authentication (sudo mode)" do
    setup %{conn: conn} do
      user = user_fixture()
      %{user: user, conn: log_in_user(conn, user)}
    end

    test "shows login page with email filled in", %{conn: conn, user: user} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "You need to reauthenticate"
      refute html =~ "Register"
      assert html =~ "Sign in"

      assert html =~
               ~s(<input type="email" name="user[email]" id="login_form_password_email" value="#{user.email}")
    end
  end
end
