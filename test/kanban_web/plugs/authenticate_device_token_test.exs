defmodule KanbanWeb.Plugs.AuthenticateDeviceTokenTest do
  use KanbanWeb.ConnCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.DevicesFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.Accounts.User
  alias Kanban.ApiTokens
  alias Kanban.Devices
  alias Kanban.Devices.Device
  alias Kanban.Repo
  alias KanbanWeb.Plugs.AuthenticateDeviceToken

  @auth_failed [:kanban, :api, :auth_failed]

  setup do
    scope = user_scope_fixture()
    {device, issued} = device_with_tokens_fixture(scope)
    %{scope: scope, device: device, access_token: issued.access_token}
  end

  defp call_with(conn, header_value) do
    conn
    |> put_req_header("authorization", header_value)
    |> AuthenticateDeviceToken.call([])
  end

  defp refute_authenticated(conn) do
    assert conn.halted
    refute Map.has_key?(conn.assigns, :current_scope)
    refute Map.has_key?(conn.assigns, :current_device)
    refute Map.has_key?(conn.assigns, :current_user)
  end

  describe "call/2 with a live access token" do
    test "assigns the scope and current_device for a live access token", %{
      conn: conn,
      scope: scope,
      device: device,
      access_token: access_token
    } do
      organization = organization_fixture()
      organization_member_fixture(organization, scope.user, :org_admin)
      assert is_nil(device.last_seen_at)

      conn = call_with(conn, "Bearer " <> access_token)

      refute conn.halted
      assert conn.assigns.current_scope.user.id == scope.user.id
      assert conn.assigns.current_scope.organization_membership.organization_id == organization.id
      assert conn.assigns.current_scope.organization_membership.role == :org_admin
      assert %Device{id: device_id, last_seen_at: %DateTime{}} = conn.assigns.current_device
      assert device_id == device.id
      assert Repo.get!(Device, device.id).last_seen_at == conn.assigns.current_device.last_seen_at

      # Agent code keys on these; a phone must never look like an agent.
      refute Map.has_key?(conn.assigns, :current_user)
      refute Map.has_key?(conn.assigns, :api_token)
    end

    test "reads the Bearer scheme case-insensitively", %{conn: conn, access_token: token} do
      for scheme <- ["bearer", "BEARER", "BeArEr"] do
        conn = call_with(conn, scheme <> " " <> token)

        refute conn.halted, "#{scheme} was refused"
        assert conn.assigns.current_device
      end
    end

    test "builds a scope with no membership for a user outside any Organization", %{
      conn: conn,
      access_token: access_token
    } do
      conn = call_with(conn, "Bearer " <> access_token)

      refute conn.halted
      assert is_nil(conn.assigns.current_scope.organization_membership)
    end
  end

  describe "call/2 refusals" do
    setup do
      attach_telemetry(@auth_failed)
      :ok
    end

    test "answers 401 for an expired token or a revoked device", %{conn: conn, scope: scope} do
      issued_at = DateTime.add(DateTime.utc_now(), -2, :hour)
      {_old_device, expired} = device_with_tokens_fixture(scope, %{}, issued_at)

      expired_conn = call_with(conn, "Bearer " <> expired.access_token)
      assert expired_conn.status == 401
      assert json_response(expired_conn, 401) == %{"error" => "Invalid access token"}
      refute_authenticated(expired_conn)

      {device, live} = device_with_tokens_fixture(scope)
      assert call_with(build_conn(), "Bearer " <> live.access_token).status == nil
      {:ok, _revoked} = Devices.revoke_device(scope, device)

      # Revoked between two requests: the second is refused.
      revoked_conn = call_with(build_conn(), "Bearer " <> live.access_token)
      assert json_response(revoked_conn, 401) == %{"error" => "Invalid access token"}
      refute_authenticated(revoked_conn)

      assert_received {:telemetry_event, @auth_failed, %{count: 1},
                       %{reason: "device_token_invalid"}}
    end

    test "answers 401 for a disabled user", %{conn: conn, scope: scope, access_token: token} do
      scope.user
      |> User.disabled_changeset(DateTime.truncate(DateTime.utc_now(), :second))
      |> Repo.update!()

      conn = call_with(conn, "Bearer " <> token)

      assert json_response(conn, 401) == %{"error" => "Invalid access token"}
      refute_authenticated(conn)
    end

    test "refuses an agent API token on /api/me", %{conn: conn, scope: scope} do
      {:ok, {_api_token, agent_token}} =
        ApiTokens.create_api_token(scope.user, ai_optimized_board_fixture(scope.user), %{
          name: "Agent"
        })

      conn = call_with(conn, "Bearer " <> agent_token)

      assert json_response(conn, 401) == %{"error" => "Invalid access token"}
      refute_authenticated(conn)
      refute conn.resp_body =~ agent_token
    end

    test "refuses a refresh token used as an access token", %{conn: conn, scope: scope} do
      {_device, issued} = device_with_tokens_fixture(scope)

      conn = call_with(conn, "Bearer " <> issued.refresh_token)

      assert json_response(conn, 401) == %{"error" => "Invalid access token"}
      refute_authenticated(conn)
    end

    test "answers 401 missing_token without a Bearer header", %{access_token: token} do
      no_header = AuthenticateDeviceToken.call(build_conn(), [])

      wrong_headers =
        Enum.map(["Basic abc", "Token " <> token, "Bearer", token], &call_with(build_conn(), &1))

      for conn <- [no_header | wrong_headers] do
        assert json_response(conn, 401) == %{"error" => "Missing or invalid Authorization header"}
        refute_authenticated(conn)
        assert_received {:telemetry_event, @auth_failed, %{count: 1}, %{reason: "missing_token"}}
      end
    end

    test "never echoes the presented token", %{conn: conn} do
      bogus = "sdat_not-a-real-token-value"

      conn = call_with(conn, "Bearer " <> bogus)

      assert conn.status == 401
      refute conn.resp_body =~ bogus
    end
  end

  # The plug has authenticated the request; the device changes before the
  # action's response is sent.
  defp authenticated(method, token) do
    conn = build_conn(method, "/api/me") |> call_with("Bearer " <> token)
    refute conn.halted
    conn
  end

  defp send_ok(conn) do
    conn
    |> put_resp_header("etag", ~s("review-v1"))
    |> put_resp_content_type("application/json")
    |> send_resp(200, ~s({"secret":"read after revocation"}))
  end

  describe "call/2 with a device revoked while the request is in flight" do
    test "a GET answers 401 instead of the data", %{scope: scope, device: device} = ctx do
      conn = authenticated(:get, ctx.access_token)
      {:ok, _revoked} = Devices.revoke_device(scope, device)

      conn = send_ok(conn)

      assert json_response(conn, 401) == %{"error" => "Invalid access token"}
      refute conn.resp_body =~ "secret"
      assert get_resp_header(conn, "etag") == []
    end

    test "a GET answers 401 when the user is disabled meanwhile", %{scope: scope} = ctx do
      conn = authenticated(:get, ctx.access_token)
      scope.user |> User.disabled_changeset(DateTime.utc_now(:second)) |> Repo.update!()

      assert json_response(send_ok(conn), 401) == %{"error" => "Invalid access token"}
    end

    test "a HEAD is re-checked like a GET", %{scope: scope, device: device} = ctx do
      conn = authenticated(:head, ctx.access_token)
      {:ok, _revoked} = Devices.revoke_device(scope, device)

      assert send_ok(conn).status == 401
    end

    test "a GET for a device still signed in is sent unchanged", ctx do
      conn = ctx.access_token |> then(&authenticated(:get, &1)) |> send_ok()

      assert json_response(conn, 200) == %{"secret" => "read after revocation"}
      assert get_resp_header(conn, "etag") == [~s("review-v1")]
    end

    test "an error response is not re-checked", %{scope: scope, device: device} = ctx do
      conn = authenticated(:get, ctx.access_token)
      {:ok, _revoked} = Devices.revoke_device(scope, device)

      assert conn |> send_resp(404, ~s({"error":"Not Found"})) |> Map.fetch!(:status) == 404
    end

    test "a write keeps the answer it committed", %{scope: scope} do
      for method <- [:post, :put, :delete] do
        {device, issued} = device_with_tokens_fixture(scope)
        conn = authenticated(method, issued.access_token)
        {:ok, _revoked} = Devices.revoke_device(scope, device)

        assert send_ok(conn).status == 200, "#{method} was rewritten"
      end
    end
  end
end
