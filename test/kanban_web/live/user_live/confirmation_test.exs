defmodule KanbanWeb.UserLive.ConfirmationTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures

  alias Kanban.Accounts

  setup do
    %{unconfirmed_user: unconfirmed_user_fixture(), confirmed_user: user_fixture()}
  end

  describe "Confirm user" do
    test "renders confirmation page for unconfirmed user", %{conn: conn, unconfirmed_user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_confirmation_instructions(user, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/users/confirm/#{token}")

      html = render(lv)
      assert html =~ "Account Confirmed!"
      assert html =~ "Your account has been confirmed successfully"
    end

    test "renders already confirmed message when trying to confirm again", %{
      conn: conn,
      unconfirmed_user: user
    } do
      first_token =
        extract_user_token(fn url ->
          Accounts.deliver_user_confirmation_instructions(user, url)
        end)

      {:ok, user} = Accounts.confirm_user(first_token)

      {encoded_token, user_token} = Accounts.UserToken.build_email_token(user, "confirm")
      Kanban.Repo.insert!(user_token)

      {:ok, lv, _html} = live(conn, ~p"/users/confirm/#{encoded_token}")

      assert_redirect(lv, ~p"/users/log-in")
    end

    test "confirms the user account", %{conn: conn, unconfirmed_user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_confirmation_instructions(user, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/users/confirm/#{token}")

      render(lv)

      assert Accounts.get_user!(user.id).confirmed_at
    end

    test "does not confirm twice with the same token", %{conn: conn, unconfirmed_user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_confirmation_instructions(user, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/users/confirm/#{token}")
      render(lv)

      {:ok, lv2, _html} = live(conn, ~p"/users/confirm/#{token}")

      assert_redirect(lv2, ~p"/users/log-in")
    end

    test "redirects to login for invalid token", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/confirm/invalid-token")

      assert_redirect(lv, ~p"/users/log-in")
    end
  end
end
