defmodule KanbanWeb.UserLive.ConfirmationPendingTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures

  alias Kanban.Accounts.UserToken
  alias Kanban.Repo

  describe "page rendering" do
    test "renders the pending page with the destination email", %{conn: conn} do
      email = unique_user_email()
      {:ok, _lv, html} = live(conn, ~p"/users/confirmation-pending?email=#{email}")

      assert html =~ "Check your email"
      assert html =~ email
      assert html =~ "won&#39;t be able to sign in until your account is confirmed"
      assert html =~ "Resend confirmation email"
    end

    test "renders for a logged-in user as well", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, _lv, html} = live(conn, ~p"/users/confirmation-pending?email=#{user.email}")
      assert html =~ "Check your email"
    end

    test "redirects to registration when the email param is missing", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/users/register"}}} =
               live(conn, ~p"/users/confirmation-pending")
    end

    test "redirects to registration when the email param is not an email", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/users/register"}}} =
               live(conn, ~p"/users/confirmation-pending?email=not an email")
    end

    test "redirects to registration when the email param is oversized", %{conn: conn} do
      oversized = String.duplicate("a", 170) <> "@example.com"

      assert {:error, {:live_redirect, %{to: "/users/register"}}} =
               live(conn, ~p"/users/confirmation-pending?email=#{oversized}")
    end
  end

  describe "resend" do
    @tag :capture_log
    test "delivers confirmation instructions for an unconfirmed account", %{conn: conn} do
      user = unconfirmed_user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/users/confirmation-pending?email=#{user.email}")

      lv |> element("button", "Resend confirmation email") |> render_click()

      assert render(lv) =~ "If your email is in our system"
      assert Repo.get_by!(UserToken, user_id: user.id, context: "confirm")
    end

    test "gives the same neutral feedback for unknown emails and creates no token", %{conn: conn} do
      email = unique_user_email()
      {:ok, lv, _html} = live(conn, ~p"/users/confirmation-pending?email=#{email}")

      lv |> element("button", "Resend confirmation email") |> render_click()

      assert render(lv) =~ "If your email is in our system"
      assert Repo.get_by(UserToken, context: "confirm") == nil
    end

    test "gives the same neutral feedback for an already-confirmed account", %{conn: conn} do
      user = user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/users/confirmation-pending?email=#{user.email}")

      lv |> element("button", "Resend confirmation email") |> render_click()

      assert render(lv) =~ "If your email is in our system"
      assert Repo.get_by(UserToken, user_id: user.id, context: "confirm") == nil
    end

    @tag :capture_log
    test "throttles repeated resend clicks", %{conn: conn} do
      user = unconfirmed_user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/users/confirmation-pending?email=#{user.email}")

      lv |> element("button", "Resend confirmation email") |> render_click()
      lv |> element("button", "Resend confirmation email") |> render_click()

      assert render(lv) =~ "Please wait a moment before requesting another email"

      tokens =
        UserToken
        |> Repo.all()
        |> Enum.filter(&(&1.user_id == user.id and &1.context == "confirm"))

      assert length(tokens) == 1
    end
  end
end
