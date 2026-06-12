defmodule KanbanWeb.UserLive.RegistrationTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures

  describe "Registration page" do
    test "renders registration page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ "Create your account"
      assert html =~ "Sign in"
    end

    test "renders inside the centered, theme-aware auth_frame", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      # Centered, theme-following shell — no light-lock, no editorial gradient.
      assert html =~ ~s(class="stride-screen")
      assert html =~ "background: var(--bg)"
      refute html =~ "data-stride-auth-frame"
      refute html =~ "linear-gradient(155deg, oklch(96% 0.025 60)"
    end

    test "no longer renders the SSO rows (no OAuth backend was ever wired)", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      refute html =~ "Continue with"
      refute html =~ "Continue with Google"
      refute html =~ "Continue with GitHub"
    end

    test "renders the terms-and-conditions checkbox", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ "I agree to the"
      assert html =~ "Terms of Service"
      assert html =~ "Acceptable Use Policy"
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/register")
        |> follow_redirect(conn, ~p"/boards")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(user: %{"email" => "with spaces"})

      assert result =~ "Create your account"
      assert result =~ "must have the @ sign and no spaces"
    end
  end

  describe "register user" do
    test "creates account without logging in", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()

      form =
        form(lv, "#registration_form",
          user: valid_user_attributes(email: email, name: "Test User")
        )

      conn = submit_form(form, conn)

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/confirmation-pending?email=#{email}"

      # Follow the redirect to the pending page and verify the copy
      {:ok, _lv, html} = live(conn, redirected_to(conn))
      assert html =~ "Check your email"
      assert html =~ email
    end

    test "renders errors for duplicated email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      user = user_fixture(%{email: "test@email.com"})

      result =
        lv
        |> form("#registration_form",
          user: %{"email" => user.email, "password" => valid_user_password()}
        )
        |> render_submit()

      assert result =~ "has already been taken"
    end

    test "renders errors for missing password", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> form("#registration_form",
          user: %{"email" => unique_user_email()}
        )
        |> render_submit()

      assert result =~ "can&#39;t be blank"
    end
  end

  describe "registration navigation" do
    test "redirects to login page when the Sign in link is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      {:ok, _login_live, login_html} =
        lv
        |> element("a", "Sign in")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert login_html =~ "Sign in"
    end
  end
end
