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

    test "shows a resend confirmation email link", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "Resend confirmation email"

      assert has_element?(
               lv,
               ~s{a[href="/users/confirmation-pending"]},
               "Resend confirmation email"
             )
    end

    test "renders inside the centered, theme-aware auth_frame", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      # Centered shell: the Stride wordmark on a canvas-backed frame that
      # follows the active theme — no light-lock, no editorial gradient.
      assert html =~ ~s(class="stride-screen")
      assert html =~ "background: var(--bg)"
      assert html =~ "Stride"
      refute html =~ "data-stride-auth-frame"
      refute html =~ "linear-gradient(155deg, oklch(96% 0.025 60)"

      # W1387: the auth form column carries the data-auth-frame anchor that the
      # app.css mobile rule targets to raise inputs/buttons to a 44px touch
      # target below md. Guard it so the touch-target containment isn't lost.
      # (The render test can only assert the anchor; the actual 44px computed
      # height is verified manually at 375px, as LiveView tests have no layout
      # engine.)
      assert html =~ "data-auth-frame"
    end

    test "no blue Tailwind classes inside the login surface", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      # Scope to the auth-frame surface (.stride-screen, the last block on the
      # page) — the surrounding NavComponents still has blue hover states.
      [_, surface] = String.split(html, ~s(class="stride-screen"), parts: 2)

      refute surface =~ ~r/(text|bg|from|to|border)-blue-\d+/
    end
  end

  describe "homepage marketing nav on auth pages" do
    test "logged-out auth page renders the homepage nav, not the stale top nav", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      # The shared marketing_nav (same as the homepage) renders its logged-out
      # CTAs and top-level links...
      assert html =~ "Start now"
      assert html =~ "Product"
      assert html =~ "Workflows"

      # ...and the stale inline root-layout nav (with its "Get Started" CTA and
      # flat "My Boards"/"Settings" links) is gone.
      refute html =~ "Get Started"
      refute html =~ "My Boards"
      refute html =~ ~s(href="/users/settings")
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
        |> element("a", "Create an account")
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

    test "logged-in auth page renders the homepage nav, not the stale flat links", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      # A logged-in user on an auth page sees the shared homepage nav's
      # logged-in affordances ("Go to boards"/"Sign out")...
      assert html =~ "Go to boards"
      assert html =~ "Sign out"

      # ...and never the stale flat top-nav links that were moved to the
      # sidebar drawer long ago.
      refute html =~ "My Boards"
      refute html =~ ~s(href="/users/settings")
      refute html =~ "Log out"
    end
  end
end
