defmodule KanbanWeb.UserAuthTest do
  use KanbanWeb.ConnCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.Accounts
  alias Kanban.Accounts.Scope
  alias Kanban.AuditLog
  alias Kanban.Organizations.Organization
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias KanbanWeb.UserAuth
  alias KanbanWeb.UserAuth.OrgAdminGate
  alias Phoenix.LiveView

  @remember_me_cookie "_kanban_web_user_remember_me"
  @remember_me_cookie_max_age 60 * 60 * 24 * 14

  setup %{conn: conn} do
    conn =
      conn
      |> Map.replace!(:secret_key_base, KanbanWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})

    %{user: %{user_fixture() | authenticated_at: DateTime.utc_now(:second)}, conn: conn}
  end

  describe "log_in_user/3" do
    test "emits user.login with the user id", %{conn: conn, user: user} do
      attach_telemetry([:kanban, :user, :login])
      user_id = user.id

      UserAuth.log_in_user(conn, user)

      assert_received {:telemetry_event, [:kanban, :user, :login], %{count: 1},
                       %{user_id: ^user_id}}
    end

    test "stores the user token in the session", %{conn: conn, user: user} do
      conn = UserAuth.log_in_user(conn, user)
      assert token = get_session(conn, :user_token)
      assert get_session(conn, :live_socket_id) == "users_sessions:#{Base.url_encode64(token)}"
      assert redirected_to(conn) == ~p"/boards"
      assert Accounts.get_user_by_session_token(token)
    end

    test "clears everything previously stored in the session", %{conn: conn, user: user} do
      conn = conn |> put_session(:to_be_removed, "value") |> UserAuth.log_in_user(user)
      refute get_session(conn, :to_be_removed)
    end

    test "keeps session when re-authenticating", %{conn: conn, user: user} do
      conn =
        conn
        |> assign(:current_scope, Scope.for_user(user))
        |> put_session(:to_be_removed, "value")
        |> UserAuth.log_in_user(user)

      assert get_session(conn, :to_be_removed)
    end

    test "clears session when user does not match when re-authenticating", %{
      conn: conn,
      user: user
    } do
      other_user = user_fixture()

      conn =
        conn
        |> assign(:current_scope, Scope.for_user(other_user))
        |> put_session(:to_be_removed, "value")
        |> UserAuth.log_in_user(user)

      refute get_session(conn, :to_be_removed)
    end

    test "redirects to the configured path", %{conn: conn, user: user} do
      conn = conn |> put_session(:user_return_to, "/hello") |> UserAuth.log_in_user(user)
      assert redirected_to(conn) == "/hello"
    end

    test "writes a cookie if remember_me is configured", %{conn: conn, user: user} do
      conn = conn |> fetch_cookies() |> UserAuth.log_in_user(user, %{"remember_me" => "true"})
      assert get_session(conn, :user_token) == conn.cookies[@remember_me_cookie]
      assert get_session(conn, :user_remember_me) == true

      assert %{value: signed_token, max_age: max_age} = conn.resp_cookies[@remember_me_cookie]
      assert signed_token != get_session(conn, :user_token)
      assert max_age == @remember_me_cookie_max_age
    end

    test "redirects to settings when user is already logged in", %{conn: conn, user: user} do
      conn =
        conn
        |> assign(:current_scope, Scope.for_user(user))
        |> UserAuth.log_in_user(user)

      assert redirected_to(conn) == ~p"/users/settings"
    end

    test "writes a cookie if remember_me was set in previous session", %{conn: conn, user: user} do
      conn = conn |> fetch_cookies() |> UserAuth.log_in_user(user, %{"remember_me" => "true"})
      assert get_session(conn, :user_token) == conn.cookies[@remember_me_cookie]
      assert get_session(conn, :user_remember_me) == true

      conn =
        conn
        |> recycle()
        |> Map.replace!(:secret_key_base, KanbanWeb.Endpoint.config(:secret_key_base))
        |> fetch_cookies()
        |> init_test_session(%{user_remember_me: true})

      # the conn is already logged in and has the remember_me cookie set,
      # now we log in again and even without explicitly setting remember_me,
      # the cookie should be set again
      conn = conn |> UserAuth.log_in_user(user, %{})
      assert %{value: signed_token, max_age: max_age} = conn.resp_cookies[@remember_me_cookie]
      assert signed_token != get_session(conn, :user_token)
      assert max_age == @remember_me_cookie_max_age
      assert get_session(conn, :user_remember_me) == true
    end
  end

  describe "logout_user/1" do
    test "erases session and cookies", %{conn: conn, user: user} do
      user_token = Accounts.generate_user_session_token(user)

      conn =
        conn
        |> put_session(:user_token, user_token)
        |> put_req_cookie(@remember_me_cookie, user_token)
        |> fetch_cookies()
        |> UserAuth.log_out_user()

      refute get_session(conn, :user_token)
      refute conn.cookies[@remember_me_cookie]
      assert %{max_age: 0} = conn.resp_cookies[@remember_me_cookie]
      assert redirected_to(conn) == ~p"/"
      refute Accounts.get_user_by_session_token(user_token)
    end

    test "broadcasts to the given live_socket_id", %{conn: conn} do
      live_socket_id = "users_sessions:abcdef-token"
      KanbanWeb.Endpoint.subscribe(live_socket_id)

      conn
      |> put_session(:live_socket_id, live_socket_id)
      |> UserAuth.log_out_user()

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^live_socket_id}
    end

    test "log out with no session", %{conn: conn} do
      attach_telemetry([:kanban, :user, :logged_out])

      conn |> fetch_cookies() |> UserAuth.log_out_user()

      assert_received {:telemetry_event, [:kanban, :user, :logged_out], %{count: 1}, metadata}
      refute Map.has_key?(metadata, :user_id)
    end

    test "emits user.logged_out with the signed-in user's id", %{conn: conn, user: user} do
      user_token = Accounts.generate_user_session_token(user)
      attach_telemetry([:kanban, :user, :logged_out])

      conn
      |> put_session(:user_token, user_token)
      |> assign(:current_scope, Scope.for_user(user))
      |> fetch_cookies()
      |> UserAuth.log_out_user()

      assert_received {:telemetry_event, [:kanban, :user, :logged_out], %{count: 1}, metadata}
      assert metadata == %{user_id: user.id}
    end

    test "works even if user is already logged out", %{conn: conn} do
      conn = conn |> fetch_cookies() |> UserAuth.log_out_user()
      refute get_session(conn, :user_token)
      assert %{max_age: 0} = conn.resp_cookies[@remember_me_cookie]
      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "fetch_current_scope_for_user/2" do
    test "authenticates user from session", %{conn: conn, user: user} do
      user_token = Accounts.generate_user_session_token(user)

      conn =
        conn |> put_session(:user_token, user_token) |> UserAuth.fetch_current_scope_for_user([])

      assert conn.assigns.current_scope.user.id == user.id
      assert conn.assigns.current_scope.user.authenticated_at == user.authenticated_at
      assert get_session(conn, :user_token) == user_token
    end

    test "authenticates user from cookies", %{conn: conn, user: user} do
      logged_in_conn =
        conn |> fetch_cookies() |> UserAuth.log_in_user(user, %{"remember_me" => "true"})

      user_token = logged_in_conn.cookies[@remember_me_cookie]
      %{value: signed_token} = logged_in_conn.resp_cookies[@remember_me_cookie]

      conn =
        conn
        |> put_req_cookie(@remember_me_cookie, signed_token)
        |> UserAuth.fetch_current_scope_for_user([])

      assert conn.assigns.current_scope.user.id == user.id
      assert conn.assigns.current_scope.user.authenticated_at == user.authenticated_at
      assert get_session(conn, :user_token) == user_token
      assert get_session(conn, :user_remember_me)

      assert get_session(conn, :live_socket_id) ==
               "users_sessions:#{Base.url_encode64(user_token)}"
    end

    test "does not authenticate if data is missing", %{conn: conn, user: user} do
      _ = Accounts.generate_user_session_token(user)
      conn = UserAuth.fetch_current_scope_for_user(conn, [])
      refute get_session(conn, :user_token)
      refute conn.assigns.current_scope
    end

    test "does not authenticate a user disabled after the session was issued", %{
      conn: conn,
      user: user
    } do
      user_token = Accounts.generate_user_session_token(user)
      {:ok, _} = Accounts.disable_user(user, admin_fixture())

      conn =
        conn |> put_session(:user_token, user_token) |> UserAuth.fetch_current_scope_for_user([])

      refute conn.assigns.current_scope
    end

    test "does not authenticate a disabled user from the remember-me cookie", %{
      conn: conn,
      user: user
    } do
      logged_in_conn =
        conn |> fetch_cookies() |> UserAuth.log_in_user(user, %{"remember_me" => "true"})

      %{value: signed_token} = logged_in_conn.resp_cookies[@remember_me_cookie]
      {:ok, _} = Accounts.disable_user(user, admin_fixture())

      conn =
        conn
        |> put_req_cookie(@remember_me_cookie, signed_token)
        |> UserAuth.fetch_current_scope_for_user([])

      refute conn.assigns.current_scope
    end

    test "authenticates a user again once they are re-enabled", %{conn: conn, user: user} do
      user_token = Accounts.generate_user_session_token(user)
      {:ok, disabled} = Accounts.disable_user(user, admin_fixture())
      {:ok, _} = Accounts.enable_user(disabled, admin_fixture())

      conn =
        conn |> put_session(:user_token, user_token) |> UserAuth.fetch_current_scope_for_user([])

      assert conn.assigns.current_scope.user.id == user.id
    end

    test "reissues a new token after a few days and refreshes cookie", %{conn: conn, user: user} do
      logged_in_conn =
        conn |> fetch_cookies() |> UserAuth.log_in_user(user, %{"remember_me" => "true"})

      token = logged_in_conn.cookies[@remember_me_cookie]
      %{value: signed_token} = logged_in_conn.resp_cookies[@remember_me_cookie]

      offset_user_token(token, -10, :day)
      {user, _} = Accounts.get_user_by_session_token(token)

      conn =
        conn
        |> put_session(:user_token, token)
        |> put_session(:user_remember_me, true)
        |> put_req_cookie(@remember_me_cookie, signed_token)
        |> UserAuth.fetch_current_scope_for_user([])

      assert conn.assigns.current_scope.user.id == user.id
      assert conn.assigns.current_scope.user.authenticated_at == user.authenticated_at
      assert new_token = get_session(conn, :user_token)
      assert new_token != token
      assert %{value: new_signed_token, max_age: max_age} = conn.resp_cookies[@remember_me_cookie]
      assert new_signed_token != signed_token
      assert max_age == @remember_me_cookie_max_age
    end

    test "reissue does not emit login", %{conn: conn, user: user} do
      attach_telemetry([:kanban, :user, :login])
      logged_in_conn = conn |> fetch_cookies() |> UserAuth.log_in_user(user)
      user_id = user.id

      # A real sign-in counts once.
      assert_received {:telemetry_event, [:kanban, :user, :login], %{count: 1},
                       %{user_id: ^user_id}}

      token = get_session(logged_in_conn, :user_token)
      offset_user_token(token, -10, :day)

      conn =
        conn
        |> put_session(:user_token, token)
        |> UserAuth.fetch_current_scope_for_user([])

      # The token was renewed, but renewing a session is not a login.
      assert get_session(conn, :user_token) != token
      refute_received {:telemetry_event, [:kanban, :user, :login], _measurements, _metadata}
    end
  end

  describe "on_mount :mount_current_scope" do
    setup %{conn: conn} do
      %{conn: UserAuth.fetch_current_scope_for_user(conn, [])}
    end

    test "assigns current_scope based on a valid user_token", %{conn: conn, user: user} do
      user_token = Accounts.generate_user_session_token(user)
      session = conn |> put_session(:user_token, user_token) |> get_session()

      {:cont, updated_socket} =
        UserAuth.on_mount(:mount_current_scope, %{}, session, %LiveView.Socket{})

      assert updated_socket.assigns.current_scope.user.id == user.id
    end

    test "assigns nil to current_scope for a user disabled after the session was issued", %{
      conn: conn,
      user: user
    } do
      user_token = Accounts.generate_user_session_token(user)
      session = conn |> put_session(:user_token, user_token) |> get_session()
      {:ok, _} = Accounts.disable_user(user, admin_fixture())

      {:cont, updated_socket} =
        UserAuth.on_mount(:mount_current_scope, %{}, session, %LiveView.Socket{})

      refute updated_socket.assigns.current_scope
    end

    test "assigns nil to current_scope assign if there isn't a valid user_token", %{conn: conn} do
      user_token = "invalid_token"
      session = conn |> put_session(:user_token, user_token) |> get_session()

      {:cont, updated_socket} =
        UserAuth.on_mount(:mount_current_scope, %{}, session, %LiveView.Socket{})

      assert updated_socket.assigns.current_scope == nil
    end

    test "assigns nil to current_scope assign if there isn't a user_token", %{conn: conn} do
      session = conn |> get_session()

      {:cont, updated_socket} =
        UserAuth.on_mount(:mount_current_scope, %{}, session, %LiveView.Socket{})

      assert updated_socket.assigns.current_scope == nil
    end
  end

  describe "on_mount :require_authenticated" do
    test "authenticates current_scope based on a valid user_token", %{conn: conn, user: user} do
      user_token = Accounts.generate_user_session_token(user)
      session = conn |> put_session(:user_token, user_token) |> get_session()

      {:cont, updated_socket} =
        UserAuth.on_mount(:require_authenticated, %{}, session, %LiveView.Socket{})

      assert updated_socket.assigns.current_scope.user.id == user.id
    end

    test "redirects to login page if there isn't a valid user_token", %{conn: conn} do
      user_token = "invalid_token"
      session = conn |> put_session(:user_token, user_token) |> get_session()

      socket = %LiveView.Socket{
        endpoint: KanbanWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      {:halt, updated_socket} = UserAuth.on_mount(:require_authenticated, %{}, session, socket)
      assert updated_socket.assigns.current_scope == nil
    end

    test "redirects a user disabled after the session was issued", %{conn: conn, user: user} do
      user_token = Accounts.generate_user_session_token(user)
      session = conn |> put_session(:user_token, user_token) |> get_session()
      {:ok, _} = Accounts.disable_user(user, admin_fixture())

      socket = %LiveView.Socket{
        endpoint: KanbanWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      {:halt, updated_socket} = UserAuth.on_mount(:require_authenticated, %{}, session, socket)
      assert updated_socket.assigns.current_scope == nil
    end

    test "redirects to login page if there isn't a user_token", %{conn: conn} do
      session = conn |> get_session()

      socket = %LiveView.Socket{
        endpoint: KanbanWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      {:halt, updated_socket} = UserAuth.on_mount(:require_authenticated, %{}, session, socket)
      assert updated_socket.assigns.current_scope == nil
    end

    test "halts and redirects if the user is unconfirmed", %{conn: conn} do
      unconfirmed_user = unconfirmed_user_fixture()
      user_token = Accounts.generate_user_session_token(unconfirmed_user)
      session = conn |> put_session(:user_token, user_token) |> get_session()

      socket = %LiveView.Socket{
        endpoint: KanbanWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      {:halt, updated_socket} = UserAuth.on_mount(:require_authenticated, %{}, session, socket)
      assert updated_socket.assigns.current_scope.user.id == unconfirmed_user.id
      assert is_nil(updated_socket.assigns.current_scope.user.confirmed_at)
    end
  end

  describe "on_mount :require_sudo_mode" do
    test "allows users that have authenticated in the last 10 minutes", %{conn: conn, user: user} do
      user_token = Accounts.generate_user_session_token(user)
      session = conn |> put_session(:user_token, user_token) |> get_session()

      socket = %LiveView.Socket{
        endpoint: KanbanWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      assert {:cont, _updated_socket} =
               UserAuth.on_mount(:require_sudo_mode, %{}, session, socket)
    end

    test "redirects when authentication is too old", %{conn: conn, user: user} do
      eleven_minutes_ago = DateTime.utc_now(:second) |> DateTime.add(-11, :minute)
      user = %{user | authenticated_at: eleven_minutes_ago}
      user_token = Accounts.generate_user_session_token(user)
      {user, token_inserted_at} = Accounts.get_user_by_session_token(user_token)
      assert DateTime.compare(token_inserted_at, user.authenticated_at) == :gt
      session = conn |> put_session(:user_token, user_token) |> get_session()

      socket = %LiveView.Socket{
        endpoint: KanbanWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      assert {:halt, _updated_socket} =
               UserAuth.on_mount(:require_sudo_mode, %{}, session, socket)
    end
  end

  describe "confirmation gate on admin/sudo authorization (D106)" do
    setup %{conn: conn} do
      socket = %LiveView.Socket{
        endpoint: KanbanWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      %{conn: conn, socket: socket}
    end

    test "on_mount :require_admin halts an unconfirmed admin", %{conn: conn, socket: socket} do
      admin =
        unconfirmed_user_fixture()
        |> Ecto.Changeset.change(type: :admin)
        |> Kanban.Repo.update!()

      token = Accounts.generate_user_session_token(admin)
      session = conn |> put_session(:user_token, token) |> get_session()

      assert {:halt, _} = UserAuth.on_mount(:require_admin, %{}, session, socket)
    end

    test "on_mount :require_sudo_mode halts an unconfirmed user", %{conn: conn, socket: socket} do
      token = Accounts.generate_user_session_token(unconfirmed_user_fixture())
      session = conn |> put_session(:user_token, token) |> get_session()

      assert {:halt, _} = UserAuth.on_mount(:require_sudo_mode, %{}, session, socket)
    end

    test "require_admin_user/2 halts an unconfirmed admin", %{conn: conn} do
      admin =
        unconfirmed_user_fixture()
        |> Ecto.Changeset.change(type: :admin)
        |> Kanban.Repo.update!()

      token = Accounts.generate_user_session_token(admin)

      conn =
        conn
        |> put_session(:user_token, token)
        |> UserAuth.fetch_current_scope_for_user([])
        |> fetch_flash()
        |> UserAuth.require_admin_user([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "require_authenticated_user/2" do
    setup %{conn: conn} do
      %{conn: UserAuth.fetch_current_scope_for_user(conn, [])}
    end

    test "redirects if user is not authenticated", %{conn: conn} do
      conn = conn |> fetch_flash() |> UserAuth.require_authenticated_user([])
      assert conn.halted

      assert redirected_to(conn) == ~p"/users/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "You must log in to access this page."
    end

    test "stores the path to redirect to on GET", %{conn: conn} do
      halted_conn =
        %{conn | path_info: ["foo"], query_string: ""}
        |> fetch_flash()
        |> UserAuth.require_authenticated_user([])

      assert halted_conn.halted
      assert get_session(halted_conn, :user_return_to) == "/foo"

      halted_conn =
        %{conn | path_info: ["foo"], query_string: "bar=baz"}
        |> fetch_flash()
        |> UserAuth.require_authenticated_user([])

      assert halted_conn.halted
      assert get_session(halted_conn, :user_return_to) == "/foo?bar=baz"

      halted_conn =
        %{conn | path_info: ["foo"], query_string: "bar", method: "POST"}
        |> fetch_flash()
        |> UserAuth.require_authenticated_user([])

      assert halted_conn.halted
      refute get_session(halted_conn, :user_return_to)
    end

    test "does not redirect if user is authenticated", %{conn: conn, user: user} do
      conn =
        conn
        |> assign(:current_scope, Scope.for_user(user))
        |> UserAuth.require_authenticated_user([])

      refute conn.halted
      refute conn.status
    end

    test "redirects if user is unconfirmed", %{conn: conn} do
      conn =
        conn
        |> assign(:current_scope, Scope.for_user(unconfirmed_user_fixture()))
        |> fetch_flash()
        |> UserAuth.require_authenticated_user([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/users/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "You must confirm your account to access this page."
    end

    test "redirects an unconfirmed user with a valid session token", %{conn: conn} do
      unconfirmed_user = unconfirmed_user_fixture()
      user_token = Accounts.generate_user_session_token(unconfirmed_user)

      conn =
        conn
        |> put_session(:user_token, user_token)
        |> UserAuth.fetch_current_scope_for_user([])
        |> fetch_flash()
        |> UserAuth.require_authenticated_user([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/users/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "You must confirm your account to access this page."
    end
  end

  describe "disconnect_sessions/1" do
    test "disconnect_sessions with no tokens" do
      attach_telemetry([:kanban, :user, :sessions_revoked])

      assert :ok = UserAuth.disconnect_sessions([])

      assert_received {:telemetry_event, [:kanban, :user, :sessions_revoked], %{count: 0},
                       metadata}

      assert metadata == %{}
    end

    test "emits user.sessions_revoked with the token count and user id", %{user: user} do
      _ = Accounts.generate_user_session_token(user)
      _ = Accounts.generate_user_session_token(user)

      {:ok, {_user, expired_tokens}} =
        Accounts.update_user_password(user, %{password: "new valid password"})

      attach_telemetry([:kanban, :user, :sessions_revoked])

      assert :ok = UserAuth.disconnect_sessions(expired_tokens)

      count = length(expired_tokens)
      assert count >= 2

      assert_received {:telemetry_event, [:kanban, :user, :sessions_revoked], %{count: ^count},
                       metadata}

      assert metadata == %{user_id: user.id}
    end

    test "broadcasts disconnect messages for each token" do
      tokens = [%{token: "token1"}, %{token: "token2"}]

      for %{token: token} <- tokens do
        KanbanWeb.Endpoint.subscribe("users_sessions:#{Base.url_encode64(token)}")
      end

      UserAuth.disconnect_sessions(tokens)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "disconnect",
        topic: "users_sessions:dG9rZW4x"
      }

      assert_receive %Phoenix.Socket.Broadcast{
        event: "disconnect",
        topic: "users_sessions:dG9rZW4y"
      }
    end
  end

  describe "disconnect_live_sessions/1" do
    test "broadcasts a disconnect per token without revoking them or emitting telemetry", %{
      user: user
    } do
      token = Accounts.generate_user_session_token(user)
      KanbanWeb.Endpoint.subscribe("users_sessions:#{Base.url_encode64(token)}")
      attach_telemetry([:kanban, :user, :sessions_revoked])

      assert :ok = user |> Accounts.list_session_tokens() |> UserAuth.disconnect_live_sessions()

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
      refute_received {:telemetry_event, [:kanban, :user, :sessions_revoked], _, _}
      assert {%{id: id}, _} = Accounts.get_user_by_session_token(token)
      assert id == user.id
    end

    test "does nothing for no tokens" do
      assert :ok = UserAuth.disconnect_live_sessions([])
    end
  end

  describe "organization membership in current_scope" do
    test "fetch_current_scope_for_user/2 loads the membership with its Organization", %{
      conn: conn,
      user: user
    } do
      organization = organization_fixture()
      organization_member_fixture(organization, user, :org_admin)
      token = Accounts.generate_user_session_token(user)

      conn = conn |> put_session(:user_token, token) |> UserAuth.fetch_current_scope_for_user([])

      assert %OrganizationMember{role: :org_admin, organization: %Organization{id: id}} =
               conn.assigns.current_scope.organization_membership

      assert id == organization.id
    end

    test "fetch_current_scope_for_user/2 leaves the membership nil for a free user", %{
      conn: conn,
      user: user
    } do
      token = Accounts.generate_user_session_token(user)

      conn = conn |> put_session(:user_token, token) |> UserAuth.fetch_current_scope_for_user([])

      assert conn.assigns.current_scope.user.id == user.id
      assert conn.assigns.current_scope.organization_membership == nil
    end

    test "on_mount loads the membership for a LiveView mount", %{conn: conn, user: user} do
      organization = organization_fixture()
      organization_member_fixture(organization, user, :member)
      token = Accounts.generate_user_session_token(user)
      session = conn |> put_session(:user_token, token) |> get_session()

      {:cont, socket} = UserAuth.on_mount(:mount_current_scope, %{}, session, %LiveView.Socket{})

      assert %OrganizationMember{role: :member, organization_id: organization_id} =
               socket.assigns.current_scope.organization_membership

      assert organization_id == organization.id
    end

    test "Scope.put_organization_membership/2 sets and clears the membership", %{user: user} do
      membership = %OrganizationMember{role: :org_admin}
      scope = user |> Scope.for_user() |> Scope.put_organization_membership(membership)

      assert scope.organization_membership == membership
      assert Scope.put_organization_membership(scope, nil).organization_membership == nil
    end
  end

  describe "on_mount :require_org_admin" do
    setup %{conn: conn} do
      # A router-mounted socket: the gate attaches a handle_params hook, which
      # LiveView only allows on a view mounted with live/3.
      socket = %LiveView.Socket{
        endpoint: KanbanWeb.Endpoint,
        router: KanbanWeb.Router,
        assigns: %{__changed__: %{}, flash: %{}},
        private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}}
      }

      %{conn: conn, socket: socket, organization: organization_fixture()}
    end

    defp mount_session(conn, user) do
      token = Accounts.generate_user_session_token(user)
      conn |> put_session(:user_token, token) |> get_session()
    end

    test "continues for an org-admin and assigns current_organization", %{
      conn: conn,
      socket: socket,
      organization: organization,
      user: user
    } do
      organization_member_fixture(organization, user, :org_admin)

      assert {:cont, socket} =
               UserAuth.on_mount(:require_org_admin, %{}, mount_session(conn, user), socket)

      assert socket.assigns.current_organization.id == organization.id
    end

    test "re-checks the role on every patch: an org-admin who stays one continues", %{
      conn: conn,
      socket: socket,
      organization: organization,
      user: user
    } do
      organization_member_fixture(organization, user, :org_admin)

      {:cont, socket} =
        UserAuth.on_mount(:require_org_admin, %{}, mount_session(conn, user), socket)

      assert {:cont, _socket} = OrgAdminGate.recheck_params(%{}, "/org", socket)
      assert AuditLog.list_events(action: :permission_denied, actor_user_id: user.id) == []
    end

    test "re-checks the role on every patch: an org-admin removed since mount is refused", %{
      conn: conn,
      socket: socket,
      organization: organization,
      user: user
    } do
      membership = organization_member_fixture(organization, user, :org_admin)

      {:cont, socket} =
        UserAuth.on_mount(:require_org_admin, %{}, mount_session(conn, user), socket)

      Repo.delete!(membership)

      assert {:halt, socket} = OrgAdminGate.recheck_params(%{}, "/org/audit", socket)
      assert socket.redirected == {:redirect, %{status: 302, to: ~p"/boards"}}

      assert Phoenix.Flash.get(socket.assigns.flash, :error) ==
               "You must be an org-admin of an Organization to access this page."

      assert [event] = AuditLog.list_events(action: :permission_denied, actor_user_id: user.id)
      assert event.metadata["gate"] == "require_org_admin"
    end

    test "refuses a member with a flash, an audit event and a redirect to /boards", %{
      conn: conn,
      socket: socket,
      organization: organization,
      user: user
    } do
      organization_member_fixture(organization, user, :member)

      assert {:halt, socket} =
               UserAuth.on_mount(:require_org_admin, %{}, mount_session(conn, user), socket)

      assert socket.redirected == {:redirect, %{status: 302, to: ~p"/boards"}}

      assert Phoenix.Flash.get(socket.assigns.flash, :error) ==
               "You must be an org-admin of an Organization to access this page."

      assert [event] = AuditLog.list_events(action: :permission_denied, actor_user_id: user.id)
      assert event.metadata["gate"] == "require_org_admin"
    end

    test "refuses a user in no Organization", %{conn: conn, socket: socket, user: user} do
      assert {:halt, socket} =
               UserAuth.on_mount(:require_org_admin, %{}, mount_session(conn, user), socket)

      assert socket.redirected == {:redirect, %{status: 302, to: ~p"/boards"}}
      assert [_event] = AuditLog.list_events(action: :permission_denied, actor_user_id: user.id)
    end

    test "refuses a site admin who is not an org-admin", %{conn: conn, socket: socket} do
      admin = admin_fixture()

      assert {:halt, socket} =
               UserAuth.on_mount(:require_org_admin, %{}, mount_session(conn, admin), socket)

      assert socket.redirected == {:redirect, %{status: 302, to: ~p"/boards"}}
      assert [_event] = AuditLog.list_events(action: :permission_denied, actor_user_id: admin.id)
    end

    test "halts an unconfirmed org-admin with the confirmation redirect", %{
      conn: conn,
      socket: socket,
      organization: organization
    } do
      unconfirmed = unconfirmed_user_fixture()
      organization_member_fixture(organization, unconfirmed, :org_admin)

      assert {:halt, socket} =
               UserAuth.on_mount(
                 :require_org_admin,
                 %{},
                 mount_session(conn, unconfirmed),
                 socket
               )

      assert socket.redirected == {:redirect, %{status: 302, to: ~p"/users/log-in"}}
      assert AuditLog.list_events(action: :permission_denied, actor_user_id: unconfirmed.id) == []
    end
  end

  describe "require_org_admin_user/2" do
    setup do
      %{organization: organization_fixture()}
    end

    defp run_org_admin_plug(conn, user) do
      token = Accounts.generate_user_session_token(user)

      conn
      |> put_session(:user_token, token)
      |> UserAuth.fetch_current_scope_for_user([])
      |> fetch_flash()
      |> UserAuth.require_org_admin_user([])
    end

    test "lets an org-admin through and assigns current_organization", %{
      conn: conn,
      organization: organization,
      user: user
    } do
      organization_member_fixture(organization, user, :org_admin)

      conn = run_org_admin_plug(conn, user)

      refute conn.halted
      assert conn.assigns.current_organization.id == organization.id
    end

    test "refuses a member with a flash, an audit event and a redirect to /boards", %{
      conn: conn,
      organization: organization,
      user: user
    } do
      organization_member_fixture(organization, user, :member)

      conn = run_org_admin_plug(conn, user)

      assert conn.halted
      assert redirected_to(conn) == ~p"/boards"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "You must be an org-admin of an Organization to access this page."

      assert [event] = AuditLog.list_events(action: :permission_denied, actor_user_id: user.id)
      assert event.metadata["gate"] == "require_org_admin"
    end

    test "refuses a user in no Organization and a site admin", %{conn: conn, user: user} do
      admin = admin_fixture()

      for refused <- [user, admin] do
        conn = run_org_admin_plug(conn, refused)

        assert conn.halted
        assert redirected_to(conn) == ~p"/boards"
        refute Map.has_key?(conn.assigns, :current_organization)
      end
    end

    test "halts an unconfirmed org-admin with the confirmation redirect", %{
      conn: conn,
      organization: organization
    } do
      unconfirmed = unconfirmed_user_fixture()
      organization_member_fixture(organization, unconfirmed, :org_admin)

      conn = run_org_admin_plug(conn, unconfirmed)

      assert conn.halted
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end
end
