defmodule KanbanWeb.UserLive.TwoFactorTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.TwoFactorHelpers

  alias KanbanWeb.TwoFactorPending

  defp pending(conn, user, opts \\ []) do
    issued_at = Keyword.get(opts, :issued_at, System.os_time(:second))
    marker = TwoFactorPending.new(user.id, Keyword.get(opts, :remember_me, false), issued_at)
    init_test_session(conn, two_factor_pending: marker)
  end

  setup %{conn: conn} do
    user = user_fixture()
    %{user: user, totp: enroll(user), conn: conn}
  end

  describe "mount" do
    test "sends a visitor with no pending sign-in back to log in", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/users/log-in", flash: flash}}} =
               live(conn, ~p"/users/two-factor")

      assert flash["error"] == "Your sign-in attempt expired. Please sign in again."
    end

    test "sends back a pending sign-in older than five minutes", %{conn: conn, user: user} do
      issued_at = System.os_time(:second) - TwoFactorPending.ttl_seconds() - 1

      assert {:error, {:live_redirect, %{to: "/users/log-in"}}} =
               conn |> pending(user, issued_at: issued_at) |> live(~p"/users/two-factor")
    end

    test "renders the code form for a pending sign-in", %{conn: conn, user: user} do
      {:ok, lv, html} = conn |> pending(user) |> live(~p"/users/two-factor")

      assert html =~ "Two-factor authentication"
      assert html =~ "Enter the 6-digit code from your authenticator app."
      assert has_element?(lv, ~s(#two_factor_form[action="/users/two-factor"]))
      assert has_element?(lv, ~s(input[name="two_factor[mode]"][value="totp"]))
      assert has_element?(lv, ~s(input[name="two_factor[code]"][autocomplete="one-time-code"]))
      assert has_element?(lv, ~s(input[name="two_factor[code]"][inputmode="numeric"]))
      assert has_element?(lv, ~s(a[href="/users/log-in"]))
    end

    test "mounting again has no side effects", %{conn: conn, user: user} do
      conn = pending(conn, user)

      {:ok, _lv, first} = live(conn, ~p"/users/two-factor")
      {:ok, _lv, second} = live(conn, ~p"/users/two-factor")

      assert first =~ "Authentication code"
      assert second =~ "Authentication code"
      assert {:ok, _pending} = TwoFactorPending.get(conn)
    end

    test "opens in recovery-code mode from ?mode=recovery", %{conn: conn, user: user} do
      {:ok, lv, html} = conn |> pending(user) |> live(~p"/users/two-factor?mode=recovery")

      assert html =~ "Recovery code"
      assert has_element?(lv, ~s(input[name="two_factor[mode]"][value="recovery"]))
    end

    test "treats any other mode as the authenticator app", %{conn: conn, user: user} do
      {:ok, lv, _html} = conn |> pending(user) |> live(~p"/users/two-factor?mode=bogus")

      assert has_element?(lv, ~s(input[name="two_factor[mode]"][value="totp"]))
    end

    test "a signed-in user re-authenticating can use it", %{conn: conn, user: user} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(user)
        |> pending(user)
        |> live(~p"/users/two-factor")

      assert html =~ "Two-factor authentication"
    end

    test "uses theme tokens, not hard-coded colours", %{conn: conn, user: user} do
      {:ok, _lv, html} = conn |> pending(user) |> live(~p"/users/two-factor")

      refute html =~ ~r/\b(bg|text|border)-(white|gray|blue|zinc)-?\d*/
      assert html =~ "var(--ink-3)"
    end
  end

  describe "switching between the app and a recovery code" do
    test "changes the label, hint, input mode and hidden mode", %{conn: conn, user: user} do
      {:ok, lv, _html} = conn |> pending(user) |> live(~p"/users/two-factor")

      html = lv |> element("#two-factor-toggle-mode") |> render_click()

      assert html =~ "Recovery code"
      assert html =~ "Enter one of the recovery codes you saved"
      assert html =~ "Use your authenticator app instead"
      assert has_element?(lv, ~s(input[name="two_factor[mode]"][value="recovery"]))
      assert has_element?(lv, ~s(input[name="two_factor[code]"][inputmode="text"]))

      html = lv |> element("#two-factor-toggle-mode") |> render_click()

      assert html =~ "Authentication code"
      assert has_element?(lv, ~s(input[name="two_factor[mode]"][value="totp"]))
    end
  end

  describe "submitting" do
    test "a valid code posts to the controller and signs in", %{
      conn: conn,
      user: user,
      totp: totp
    } do
      conn = pending(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/users/two-factor")

      form = form(lv, "#two_factor_form", two_factor: %{code: code(totp.secret, 1)})
      render_submit(form)
      conn = follow_trigger_action(form, conn)

      assert redirected_to(conn) == ~p"/boards"
      assert get_session(conn, :user_token)
    end

    test "a wrong code comes back to the challenge with an error", %{conn: conn, user: user} do
      conn = pending(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/users/two-factor")

      form = form(lv, "#two_factor_form", two_factor: %{code: "000000"})
      render_submit(form)
      conn = follow_trigger_action(form, conn)

      assert redirected_to(conn) == ~p"/users/two-factor"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "That code is not valid. Check it and try again."
    end

    test "a recovery code in recovery mode signs in", %{conn: conn, user: user, totp: totp} do
      conn = pending(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/users/two-factor?mode=recovery")

      [recovery | _rest] = totp.recovery_codes
      # The hidden mode field carries "recovery"; a browser submits it with the code.
      form = form(lv, "#two_factor_form", two_factor: %{code: recovery, mode: "recovery"})
      render_submit(form)
      conn = follow_trigger_action(form, conn)

      assert redirected_to(conn) == ~p"/boards"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "recovery code"
    end
  end
end
