defmodule KanbanWeb.UserLive.ForgotPasswordTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures

  alias Kanban.Repo

  describe "Forgot password page" do
    test "renders forgot password page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/forgot-password")

      assert html =~ "Reset your password"
      assert html =~ "We&#39;ll email a one-time link"
    end

    test "renders inside the centered, theme-aware auth_frame", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/forgot-password")

      # Centered, theme-following shell — no light-lock, no editorial gradient.
      assert html =~ ~s(class="stride-screen")
      assert html =~ "background: var(--bg)"
      refute html =~ "data-stride-auth-frame"
      refute html =~ "linear-gradient(155deg, oklch(96% 0.025 60)"
    end

    test "renders the For-agents callout panel", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/forgot-password")

      assert html =~ "For agents:"
      assert html =~ "rotate API tokens"
      assert html =~ "Board → Tokens"
    end

    test "footer_switch is a Back-to-sign-in link", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/forgot-password")

      assert html =~ "Back to sign in"
    end
  end

  describe "Reset link request" do
    @tag :capture_log
    test "sends a new reset password token", %{conn: conn} do
      user = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/users/forgot-password")

      {:ok, conn} =
        lv
        |> form("#reset_password_form", user: %{email: user.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/")

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "If your email is in our system"

      assert Repo.get_by!(Kanban.Accounts.UserToken, user_id: user.id).context ==
               "reset_password"
    end

    test "does not send reset password token if email is invalid", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/forgot-password")

      {:ok, conn} =
        lv
        |> form("#reset_password_form", user: %{email: "unknown@example.com"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/")

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "If your email is in our system"

      assert Repo.get_by(Kanban.Accounts.UserToken, context: "reset_password") == nil
    end
  end
end
