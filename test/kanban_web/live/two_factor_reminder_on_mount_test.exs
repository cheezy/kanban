defmodule KanbanWeb.TwoFactorReminderOnMountTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.TwoFactorHelpers

  alias Kanban.Accounts
  alias Kanban.Accounts.Scope
  alias Kanban.Repo
  alias KanbanWeb.TwoFactorReminderOnMount
  alias Phoenix.LiveView.Socket

  @card "#two-factor-reminder"
  @dismiss "#two-factor-reminder-dismiss"

  # register_and_log_in_user/1 puts a token straight into the session and sets
  # no flash, so these tests sign in through the real password POST.
  defp sign_in(conn, user) do
    post(conn, ~p"/users/log-in", %{
      "user" => %{"email" => user.email, "password" => valid_user_password()}
    })
  end

  defp land(conn, user) do
    conn = sign_in(conn, user)
    {:ok, view, html} = live(conn, redirected_to(conn))
    {view, html}
  end

  defp scope_socket(scope, flash) do
    %Socket{assigns: %{__changed__: %{}, current_scope: scope, flash: flash}}
  end

  describe "after a password sign-in" do
    test "shows the reminder on the landing page after sign-in", %{conn: conn} do
      {view, html} = land(conn, user_fixture())

      assert html =~ ~s(id="two-factor-reminder")

      assert has_element?(
               view,
               ~s|main section#two-factor-reminder[aria-labelledby="two-factor-reminder-title"]|
             )

      assert has_element?(view, "h2#two-factor-reminder-title")
      refute has_element?(view, ~s|#{@card}[role="alert"]|)
      refute has_element?(view, ~s|#{@card}[aria-live]|)
    end

    test "shows the reminder on the deep-linked page the user returns to", %{conn: conn} do
      conn = get(conn, ~p"/notifications")
      assert redirected_to(conn) == ~p"/users/log-in"

      conn = sign_in(conn, user_fixture())
      assert redirected_to(conn) == ~p"/notifications"

      {:ok, view, _html} = live(conn, ~p"/notifications")
      assert has_element?(view, @card)
    end

    test "the reminder links to two-factor settings and the guide", %{conn: conn} do
      {view, _html} = land(conn, user_fixture())

      assert has_element?(view, ~s|#{@card} a[href="/users/settings?section=two_factor"]|)
      assert has_element?(view, ~s|#{@card} a[href="/resources/two-factor-authentication"]|)
      assert has_element?(view, ~s|#{@dismiss}[phx-click*="dismiss_two_factor_reminder"]|)
    end

    test "Not now hides the reminder and the next sign-in within 10 days does not show it",
         %{conn: conn} do
      user = user_fixture()
      {view, _html} = land(conn, user)

      view |> element(@dismiss) |> render_click()

      refute has_element?(view, @card)
      assert %DateTime{} = Repo.reload!(user).two_factor_reminder_dismissed_at

      conn = sign_in(build_conn(), user)
      refute Phoenix.Flash.get(conn.assigns.flash, :two_factor_reminder)

      {:ok, next_view, _html} = live(conn, redirected_to(conn))
      refute has_element?(next_view, @card)
    end

    test "the reminder is gone after navigating to another page", %{conn: conn} do
      {view, _html} = land(conn, user_fixture())
      assert has_element?(view, @card)

      {:ok, other, _html} = live_redirect(view, to: ~p"/notifications")

      refute has_element?(other, @card)
    end

    test "the reminder is gone after a reload", %{conn: conn} do
      conn = sign_in(conn, user_fixture())
      conn = get(conn, ~p"/boards")
      assert html_response(conn, 200) =~ ~s(id="two-factor-reminder")

      {:ok, view, _html} = live(conn, ~p"/boards")
      refute has_element?(view, @card)
    end

    test "dismissing ignores a user id sent in the event params", %{conn: conn} do
      me = user_fixture()
      other = user_fixture()
      {view, _html} = land(conn, me)

      view
      |> element(@dismiss)
      |> render_click(%{"user_id" => to_string(other.id), "id" => to_string(other.id)})

      assert %DateTime{} = Repo.reload!(me).two_factor_reminder_dismissed_at
      assert Repo.reload!(other).two_factor_reminder_dismissed_at == nil
    end

    test "a user who signs in with two-factor never sees the reminder", %{conn: conn} do
      user = user_fixture()
      %{secret: secret} = enroll(user)

      conn = sign_in(conn, user)
      assert redirected_to(conn) == ~p"/users/two-factor"

      conn =
        post(conn, ~p"/users/two-factor", %{
          "two_factor" => %{"code" => code(secret, 1), "mode" => "totp"}
        })

      {:ok, view, _html} = live(conn, redirected_to(conn))
      refute has_element?(view, @card)
    end

    test "a controller-rendered landing page shows no card and no error", %{conn: conn} do
      conn = sign_in(conn, user_fixture())
      conn = get(conn, ~p"/about")

      refute html_response(conn, 200) =~ ~s(id="two-factor-reminder")
    end
  end

  describe "on_mount/4" do
    test "leaves a socket without a signed-in user alone" do
      socket = scope_socket(nil, %{"two_factor_reminder" => true})

      assert {:cont, ^socket} = TwoFactorReminderOnMount.on_mount(:default, %{}, %{}, socket)
    end

    test "leaves the flag false without the flash" do
      scope = Scope.for_user(user_fixture())

      assert {:cont, socket} =
               TwoFactorReminderOnMount.on_mount(:default, %{}, %{}, scope_socket(scope, %{}))

      refute socket.assigns.current_scope.two_factor_reminder
    end

    test "sets the flag from the flash on the disconnected render" do
      scope = Scope.for_user(user_fixture())
      socket = scope_socket(scope, %{"two_factor_reminder" => true})

      assert {:cont, socket} = TwoFactorReminderOnMount.on_mount(:default, %{}, %{}, socket)
      assert socket.assigns.current_scope.two_factor_reminder
    end
  end

  describe "handle_reminder_event/3" do
    test "passes other events through" do
      socket = scope_socket(Scope.for_user(user_fixture()), %{})

      assert {:cont, ^socket} =
               TwoFactorReminderOnMount.handle_reminder_event("save", %{}, socket)
    end

    test "a second dismissal halts without writing again" do
      user = user_fixture()
      scope = %{Scope.for_user(user) | two_factor_reminder: false}

      assert {:halt, socket} =
               TwoFactorReminderOnMount.handle_reminder_event(
                 "dismiss_two_factor_reminder",
                 %{},
                 scope_socket(scope, %{})
               )

      refute socket.assigns.current_scope.two_factor_reminder
      assert Repo.reload!(user).two_factor_reminder_dismissed_at == nil
      assert Accounts.show_two_factor_reminder?(user)
    end
  end
end
