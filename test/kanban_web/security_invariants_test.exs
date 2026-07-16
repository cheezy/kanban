defmodule KanbanWeb.SecurityInvariantsTest do
  @moduledoc """
  SECURITY INVARIANTS — DO NOT WEAKEN THESE ASSERTIONS TO MAKE A CHANGE PASS.

  Each test here pins a load-bearing authentication/authorization gate that must
  stay wired. If your change makes one of these fail, the correct response is
  almost never "update the assertion" — it is "you removed a security control,
  put it back (or bring a deliberate, reviewed decision to change it)."

  Why this module exists: task D155. An unrelated commit (3df1c9a8, W637 — a
  change to add icon attributes) silently stripped the sudo-mode re-authentication
  gate from the account-settings and password/email-change flows AND rewrote the
  settings test to assert the now-vulnerable behavior, so CI stayed green and the
  regression shipped. It was only caught by a manual pre-handoff security review.
  This module raises the cost of that class of silent regression: it asserts the
  gates both structurally (the router wiring) and behaviorally (the flow), so a
  change that moves the routes out of the sudo live_session, or drops the
  controller plug, breaks a clearly-named security test rather than sliding by.
  """
  use KanbanWeb.ConnCase, async: true

  import Kanban.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Kanban.Accounts

  # A session authenticated longer ago than any reasonable sudo window. Kept
  # generously stale so it survives a change to the Accounts.sudo_mode? default,
  # rather than pinning the exact minutes the gate uses.
  @stale_authenticated_at DateTime.utc_now(:second) |> DateTime.add(-1, :hour)

  describe "sudo-mode gate on account settings (D155)" do
    test "the settings routes are wired into the :require_sudo_mode live_session" do
      for path <- ["/users/settings", "/users/settings/confirm-email/:token"] do
        {live_session_name, on_mount_ids} = live_session_for_path(path)

        assert live_session_name == :require_sudo_mode,
               "#{path} must live in the :require_sudo_mode live_session, " <>
                 "found #{inspect(live_session_name)} — a credential-changing route " <>
                 "was moved out from behind the re-authentication gate (see D155)."

        assert {KanbanWeb.UserAuth, :require_sudo_mode} in on_mount_ids,
               "#{path} must carry the {KanbanWeb.UserAuth, :require_sudo_mode} on_mount, " <>
                 "found #{inspect(on_mount_ids)} (see D155)."
      end
    end

    test "a session outside the sudo window is bounced to re-authenticate before reaching settings" do
      assert {:error, {:redirect, %{to: to, flash: flash}}} =
               build_conn()
               |> log_in_user(user_fixture(), token_authenticated_at: @stale_authenticated_at)
               |> live(~p"/users/settings")

      assert to == ~p"/users/log-in"
      assert %{"error" => _} = flash
    end
  end

  describe "sudo-mode gate on the password-change POST (D155)" do
    test "a stale-sudo POST to /users/update-password is redirected and does not change the password" do
      user = user_fixture()
      new_password = "an attacker chosen password"

      conn =
        build_conn()
        |> log_in_user(user, token_authenticated_at: @stale_authenticated_at)
        |> post(~p"/users/update-password", %{
          "user" => %{
            "email" => user.email,
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      assert redirected_to(conn) == ~p"/users/log-in"
      # The credential was NOT changed — the old password still authenticates.
      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
      refute Accounts.get_user_by_email_and_password(user.email, new_password)
    end
  end

  # Returns {live_session_name, [on_mount_id, ...]} for the route at `path`,
  # read from the compiled router table so the assertion tracks the actual
  # wiring rather than any single behavioral path. Looked up by path (never by
  # position) so it is resilient to route reordering.
  defp live_session_for_path(path) do
    route =
      KanbanWeb.Router
      |> Phoenix.Router.routes()
      |> Enum.find(&(&1.path == path))

    assert route, "no route found for #{path} — did the settings route path change?"

    {_view, _action, _opts, live_session} = route.metadata.phoenix_live_view
    on_mount_ids = Enum.map(live_session.extra.on_mount, & &1.id)

    {live_session.name, on_mount_ids}
  end
end
