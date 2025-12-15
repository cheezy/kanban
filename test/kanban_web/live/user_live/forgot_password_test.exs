defmodule KanbanWeb.UserLive.ForgotPasswordTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures

  alias Kanban.Repo

  describe "Forgot password page" do
    test "renders forgot password page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/forgot-password")

      assert html =~ "Forgot your password?"
      assert html =~ "We&#39;ll send you an email with instructions"
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
