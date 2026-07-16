defmodule KanbanWeb.UserLive.ResetPasswordTest do
  use KanbanWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures

  alias Kanban.Accounts
  alias Kanban.Accounts.UserToken
  alias Kanban.Repo

  setup do
    user = user_fixture()

    token =
      extract_user_token(fn url ->
        Accounts.deliver_user_reset_password_instructions(user, url)
      end)

    %{token: token, user: user}
  end

  describe "Reset password page" do
    test "renders reset password page with valid token", %{conn: conn, token: token} do
      {:ok, _lv, html} = live(conn, ~p"/users/reset-password/#{token}")

      assert html =~ "Reset password"
      assert html =~ "New password"
    end

    test "does not render reset password page with invalid token", %{conn: conn} do
      {:error, {:redirect, to}} = live(conn, ~p"/users/reset-password/invalid")

      assert to == %{
               flash: %{"error" => "Reset password link is invalid or it has expired."},
               to: ~p"/"
             }
    end

    test "an expired reset link shows the invalid/expired flash and redirects to / (D136)", %{
      conn: conn,
      token: token,
      user: user
    } do
      # A real (not malformed) token pushed just past the enforced 15-minute
      # window must behave exactly like an invalid one.
      just_outside =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(-(UserToken.reset_password_validity_in_minutes() + 1), :minute)
        |> NaiveDateTime.truncate(:second)

      {1, nil} =
        from(t in UserToken, where: t.user_id == ^user.id)
        |> Repo.update_all(set: [inserted_at: just_outside])

      {:error, {:redirect, to}} = live(conn, ~p"/users/reset-password/#{token}")

      assert to == %{
               flash: %{"error" => "Reset password link is invalid or it has expired."},
               to: ~p"/"
             }
    end

    test "renders errors for invalid data", %{conn: conn, token: token} do
      {:ok, lv, _html} = live(conn, ~p"/users/reset-password/#{token}")

      result =
        lv
        |> element("#reset_password_form")
        |> render_change(
          user: %{
            "password" => "short",
            "password_confirmation" => "secret123456"
          }
        )

      assert result =~ "should be at least 12 character"
      assert result =~ "does not match password"
    end
  end

  describe "Reset password" do
    test "resets password once", %{conn: conn, token: token, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/reset-password/#{token}")

      {:ok, conn} =
        lv
        |> form("#reset_password_form",
          user: %{
            password: "new valid password",
            password_confirmation: "new valid password"
          }
        )
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Password reset successfully"
      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
    end

    test "disconnects the user's active sockets on reset", %{conn: conn, token: token, user: user} do
      # An already-mounted session for this user. disconnect_sessions/1
      # broadcasts on the session topic derived from the raw session token.
      session_token = Accounts.generate_user_session_token(user)
      KanbanWeb.Endpoint.subscribe("users_sessions:#{Base.url_encode64(session_token)}")

      {:ok, lv, _html} = live(conn, ~p"/users/reset-password/#{token}")

      lv
      |> form("#reset_password_form",
        user: %{
          password: "new valid password",
          password_confirmation: "new valid password"
        }
      )
      |> render_submit()

      assert_receive %Phoenix.Socket.Broadcast{
        event: "disconnect",
        topic: "users_sessions:" <> _
      }
    end

    test "does not reset password on invalid data", %{conn: conn, token: token} do
      {:ok, lv, _html} = live(conn, ~p"/users/reset-password/#{token}")

      result =
        lv
        |> form("#reset_password_form",
          user: %{
            password: "short",
            password_confirmation: "secret123456"
          }
        )
        |> render_submit()

      assert result =~ "Reset password"
      assert result =~ "should be at least 12 character"
      assert result =~ "does not match password"
    end
  end

  describe "Reset password navigation" do
    test "redirects to login page when clicking back to login", %{conn: conn, token: token} do
      {:ok, lv, _html} = live(conn, ~p"/users/reset-password/#{token}")

      {:ok, _login_live, login_html} =
        lv
        |> element("a", "Back to sign in")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/log-in")

      # Login page title was updated to "Sign in" in W652 per design auth.jsx:296.
      assert login_html =~ "Sign in"
    end
  end
end
