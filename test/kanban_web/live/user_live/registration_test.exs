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

    test "renders inside the editorial auth_frame", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      # The auth_frame brand panel renders the rotating signup quote
      assert html =~ "shipped 38"
      assert html =~ "linear-gradient(155deg, oklch(96% 0.025 60)"
    end

    test "renders the SSO rows (Google + GitHub) per design's Sign Up state", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ "Continue with"
      assert html =~ "Google"
      assert html =~ "GitHub"
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
    test "creates account and logs in automatically", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()

      form =
        form(lv, "#registration_form",
          user: valid_user_attributes(email: email, name: "Test User")
        )

      conn = submit_form(form, conn)

      assert redirected_to(conn) == ~p"/boards"

      # Follow the redirect to verify the flash message
      conn = get(conn, ~p"/boards")
      assert html_response(conn, 200) =~ "Account created successfully"
      assert html_response(conn, 200) =~ "Please check your email to confirm your account"
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
        |> element("main a", "Sign in")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert login_html =~ "Sign in"
    end
  end
end
