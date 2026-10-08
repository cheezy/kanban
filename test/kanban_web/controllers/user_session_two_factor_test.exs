defmodule KanbanWeb.UserSessionTwoFactorTest do
  use KanbanWeb.ConnCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.TwoFactorHelpers

  alias Kanban.Accounts
  alias Kanban.AuditLog
  alias KanbanWeb.TwoFactorPending

  @remember_me_cookie "_kanban_web_user_remember_me"

  defp log_in(conn, user, extra \\ %{}) do
    post(conn, ~p"/users/log-in", %{
      "user" => Map.merge(%{"email" => user.email, "password" => valid_user_password()}, extra)
    })
  end

  defp verify(conn, code, mode \\ "totp") do
    post(conn, ~p"/users/two-factor", %{"two_factor" => %{"code" => code, "mode" => mode}})
  end

  defp audit_actions(user) do
    [actor_user_id: user.id]
    |> AuditLog.list_events()
    |> Enum.map(& &1.action)
  end

  defp flash(conn, key), do: Phoenix.Flash.get(conn.assigns.flash, key)

  setup do
    user = user_fixture()
    %{user: user, totp: enroll(user)}
  end

  describe "POST /users/log-in for a user with two-factor on" do
    test "sends the user to the challenge with no session token", %{conn: conn, user: user} do
      conn = log_in(conn, user, %{"remember_me" => "true"})

      assert redirected_to(conn) == ~p"/users/two-factor"
      refute get_session(conn, :user_token)
      refute conn.resp_cookies[@remember_me_cookie]
      assert {:ok, %{user_id: id, remember_me: true}} = TwoFactorPending.get(conn)
      assert id == user.id
    end

    test "a wrong password still says nothing about two-factor", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => "wrong password!"}
        })

      assert redirected_to(conn) == ~p"/users/log-in"
      assert flash(conn, :error) == "Invalid email or password"
      assert TwoFactorPending.get(conn) == {:error, :expired}
    end

    test "an unconfirmed account is still sent to confirm first", %{conn: conn} do
      user = unconfirmed_user_fixture()
      enroll(user)

      conn = log_in(conn, user)

      assert redirected_to(conn) =~ ~p"/users/confirmation-pending"
      assert TwoFactorPending.get(conn) == {:error, :expired}
    end
  end

  describe "POST /users/two-factor with a TOTP code" do
    test "logs the user in and clears the marker", %{conn: conn, user: user, totp: totp} do
      conn = conn |> log_in(user) |> verify(code(totp.secret, 1))

      assert redirected_to(conn) == ~p"/boards"
      assert get_session(conn, :user_token)
      assert flash(conn, :info) == "Welcome back!"
      assert TwoFactorPending.get(conn) == {:error, :expired}
      assert "login_succeeded_two_factor" in audit_actions(user)
    end

    test "accepts a code with surrounding whitespace", %{conn: conn, user: user, totp: totp} do
      conn = conn |> log_in(user) |> verify("  #{code(totp.secret, 1)} \n")

      assert redirected_to(conn) == ~p"/boards"
      assert get_session(conn, :user_token)
    end

    test "refuses a wrong code and keeps the marker", %{conn: conn, user: user} do
      conn = conn |> log_in(user) |> verify("000000")

      assert redirected_to(conn) == ~p"/users/two-factor"
      assert flash(conn, :error) == "That code is not valid. Check it and try again."
      refute get_session(conn, :user_token)
      assert {:ok, _pending} = TwoFactorPending.get(conn)
      assert "two_factor_challenge_failed" in audit_actions(user)
    end

    test "refuses a code that was already used", %{conn: conn, user: user, totp: totp} do
      used = code(totp.secret, 1)
      assert Accounts.valid_two_factor_code?(user, used)

      conn = conn |> log_in(user) |> verify(used)

      assert redirected_to(conn) == ~p"/users/two-factor"
      refute get_session(conn, :user_token)
    end

    test "honours remember-me from the password step", %{conn: conn, user: user, totp: totp} do
      conn = conn |> log_in(user, %{"remember_me" => "true"}) |> verify(code(totp.secret, 1))

      assert get_session(conn, :user_token)
      assert %{value: signed_token} = conn.resp_cookies[@remember_me_cookie]
      assert signed_token != get_session(conn, :user_token)
      assert get_session(conn, :user_remember_me)
    end

    test "sets no remember-me cookie when it was not chosen", %{
      conn: conn,
      user: user,
      totp: totp
    } do
      conn = conn |> log_in(user, %{"remember_me" => "false"}) |> verify(code(totp.secret, 1))

      assert get_session(conn, :user_token)
      refute conn.resp_cookies[@remember_me_cookie]
    end

    test "returns to the page the user was sent from", %{conn: conn, user: user, totp: totp} do
      conn =
        conn
        |> init_test_session(user_return_to: "/foo/bar")
        |> log_in(user)
        |> verify(code(totp.secret, 1))

      assert redirected_to(conn) == "/foo/bar"
    end

    test "cannot be replayed with a copy of the pre-success session", %{
      conn: conn,
      user: user,
      totp: totp
    } do
      pending_conn = log_in(conn, user)
      valid = code(totp.secret, 1)

      assert pending_conn |> verify(valid) |> get_session(:user_token)

      replayed = verify(pending_conn, valid)

      assert redirected_to(replayed) == ~p"/users/two-factor"
      refute get_session(replayed, :user_token)
    end
  end

  describe "POST /users/two-factor with a recovery code" do
    test "logs in once, uses the code up and recommends new codes", %{
      conn: conn,
      user: user,
      totp: totp
    } do
      [recovery | _rest] = totp.recovery_codes

      signed_in = conn |> log_in(user) |> verify(recovery, "recovery")

      assert redirected_to(signed_in) == ~p"/boards"
      assert get_session(signed_in, :user_token)
      assert flash(signed_in, :info) =~ "recovery code"
      assert flash(signed_in, :info) =~ "Settings → Two-factor"

      actions = audit_actions(user)
      assert "two_factor_recovery_code_used" in actions
      assert "login_succeeded_two_factor" in actions

      again = build_conn() |> log_in(user) |> verify(recovery, "recovery")

      assert redirected_to(again) == ~p"/users/two-factor?mode=recovery"
      refute get_session(again, :user_token)
    end
  end

  describe "POST /users/two-factor without a usable marker" do
    test "sends the visitor back to log in", %{conn: conn} do
      conn = verify(conn, "123456")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert flash(conn, :error) == "Your sign-in attempt expired. Please sign in again."
      refute get_session(conn, :user_token)
    end

    test "refuses a marker older than five minutes", %{conn: conn, user: user, totp: totp} do
      issued_at = System.os_time(:second) - TwoFactorPending.ttl_seconds() - 1

      conn =
        conn
        |> init_test_session(two_factor_pending: TwoFactorPending.new(user.id, false, issued_at))
        |> verify(code(totp.secret, 1))

      assert redirected_to(conn) == ~p"/users/log-in"
      refute get_session(conn, :user_token)
      assert get_session(conn, :two_factor_pending) == nil
    end

    test "refuses a user disabled while the challenge was pending", %{
      conn: conn,
      user: user,
      totp: totp
    } do
      pending_conn = log_in(conn, user)
      {:ok, _disabled} = Accounts.disable_user(user, admin_fixture())

      conn = verify(pending_conn, code(totp.secret, 1))

      assert redirected_to(conn) == ~p"/users/log-in"
      assert flash(conn, :error) == "Your sign-in attempt expired. Please sign in again."
      refute get_session(conn, :user_token)
    end

    test "refuses a user who turned two-factor off while it was pending", %{
      conn: conn,
      user: user,
      totp: totp
    } do
      pending_conn = log_in(conn, user)
      [recovery | _rest] = totp.recovery_codes
      :ok = Accounts.disable_two_factor(user, recovery)

      conn = verify(pending_conn, code(totp.secret, 1))

      assert redirected_to(conn) == ~p"/users/log-in"
      refute get_session(conn, :user_token)
    end

    test "logging out clears the marker", %{conn: conn, user: user} do
      conn = conn |> log_in(user) |> delete(~p"/users/log-out")

      assert get_session(conn, :two_factor_pending) == nil
    end
  end

  describe "re-authentication (sudo mode)" do
    test "also needs the second factor", %{conn: conn, user: user, totp: totp} do
      stale = :second |> DateTime.utc_now() |> DateTime.add(-20, :minute)
      conn = log_in_user(conn, user, token_authenticated_at: stale)

      challenged = log_in(conn, user)
      assert redirected_to(challenged) == ~p"/users/two-factor"

      assert challenged |> get(~p"/users/settings") |> redirected_to() == ~p"/users/log-in"

      verified = verify(challenged, code(totp.secret, 1))

      assert redirected_to(verified) == ~p"/users/settings"
      assert get_session(verified, :two_factor_pending) == nil
      assert verified |> get(~p"/users/settings") |> html_response(200)
    end

    test "a password change does not ask for the second factor again", %{conn: conn, user: user} do
      new_password = "a brand new password!"

      conn =
        conn
        |> log_in_user(user)
        |> post(~p"/users/update-password", %{
          "user" => %{
            "email" => user.email,
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      assert redirected_to(conn) == ~p"/users/settings"
      assert flash(conn, :info) == "Password updated successfully!"
      assert get_session(conn, :user_token)
      assert Accounts.get_user_by_email_and_password(user.email, new_password)
    end
  end

  describe "the two-factor reminder at sign-in" do
    test "password sign-in without two-factor sets the reminder flash", %{conn: conn} do
      user = user_fixture()

      conn = log_in(conn, user)

      assert redirected_to(conn) == ~p"/boards"
      assert get_session(conn, :user_token)
      assert flash(conn, :two_factor_reminder) == true
      assert flash(conn, :info) == "Welcome back!"
    end

    test "no reminder flash for a two-factor user or a snoozed user", %{
      conn: conn,
      user: user,
      totp: totp
    } do
      challenged = log_in(conn, user)
      assert redirected_to(challenged) == ~p"/users/two-factor"
      refute flash(challenged, :two_factor_reminder)

      verified = verify(challenged, code(totp.secret, 1))
      assert get_session(verified, :user_token)
      refute flash(verified, :two_factor_reminder)

      snoozed = user_fixture()
      {:ok, _snoozed} = Accounts.dismiss_two_factor_reminder(snoozed)

      conn = log_in(build_conn(), snoozed)
      assert get_session(conn, :user_token)
      refute flash(conn, :two_factor_reminder)
    end

    test "a password change never sets the reminder", %{conn: conn} do
      user = user_fixture()
      new_password = "a brand new password!"

      conn =
        conn
        |> log_in_user(user)
        |> post(~p"/users/update-password", %{
          "user" => %{
            "email" => user.email,
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      assert redirected_to(conn) == ~p"/users/settings"
      assert get_session(conn, :user_token)
      refute flash(conn, :two_factor_reminder)
    end
  end
end
