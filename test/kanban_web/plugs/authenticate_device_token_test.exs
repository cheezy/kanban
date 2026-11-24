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
  alias KanbanWeb.Plugs.AuthenticateApiToken
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

    test "wrong token kind carries the challenge", %{scope: scope, access_token: device_token} do
      {:ok, {_api_token, agent_token}} =
        ApiTokens.create_api_token(scope.user, ai_optimized_board_fixture(scope.user), %{
          name: "Agent"
        })

      {_device, issued} = device_with_tokens_fixture(scope)

      # An agent token or a refresh token on /api/me.
      for token <- [agent_token, issued.refresh_token] do
        conn = call_with(build_conn(), "Bearer " <> token)

        assert json_response(conn, 401) == %{"error" => "Invalid access token"}
        assert get_resp_header(conn, "www-authenticate") == [~s(Bearer error="invalid_token")]
      end

      # A device access token on an agent route.
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> device_token)
        |> AuthenticateApiToken.call([])

      assert json_response(conn, 401) == %{"error" => "Invalid API token"}
      assert get_resp_header(conn, "www-authenticate") == [~s(Bearer error="invalid_token")]
    end

    test "401 body unchanged", %{scope: scope} do
      {_device, expired} =
        device_with_tokens_fixture(scope, %{}, DateTime.add(DateTime.utc_now(), -2, :hour))

      missing = AuthenticateDeviceToken.call(build_conn(), [])

      assert json_response(missing, 401) == %{
               "error" => "Missing or invalid Authorization header"
             }

      assert get_resp_header(missing, "www-authenticate") == ["Bearer"]

      for header <- ["Bearer sdat_not-a-real-token", "Bearer " <> expired.access_token] do
        conn = call_with(build_conn(), header)

        assert json_response(conn, 401) == %{"error" => "Invalid access token"}
        assert get_resp_header(conn, "www-authenticate") == [~s(Bearer error="invalid_token")]
      end
    end

    test "never echoes the presented token", %{conn: conn} do
      bogus = "sdat_not-a-real-token-value"

      conn = call_with(conn, "Bearer " <> bogus)

      assert conn.status == 401
      refute conn.resp_body =~ bogus
    end
  end

  describe "call/2 once an address has failed too often" do
    setup do
      original = Application.get_env(:kanban, Kanban.RateLimit)
      Application.put_env(:kanban, Kanban.RateLimit, enabled: true)
      on_exit(fn -> Application.put_env(:kanban, Kanban.RateLimit, original) end)

      attach_telemetry(@auth_failed)
      ip = {10, :rand.uniform(255), :rand.uniform(255), :rand.uniform(255)}
      %{ip: ip}
    end

    defp from_ip(ip, header_value),
      do: call_with(%{build_conn() | remote_ip: ip}, header_value)

    test "answers 429 with retry-after, even for a live token, and emits rate_limited", %{
      ip: ip,
      access_token: token
    } do
      # :api_token allows 20 failed authentications a minute per address.
      for _ <- 1..20 do
        assert from_ip(ip, "Bearer sdat_wrong").status == 401
      end

      conn = from_ip(ip, "Bearer " <> token)

      assert json_response(conn, 429) == %{"error" => "Too many requests"}
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) in 1..61
      refute_authenticated(conn)
      assert get_resp_header(conn, "www-authenticate") == []

      assert_received {:telemetry_event, @auth_failed, %{count: 1},
                       %{reason: "rate_limited", path: "/", method: "GET"}}

      # Another address is unaffected.
      refute from_ip({10, 0, 0, 1}, "Bearer " <> token).halted
    end

    test "expired device tokens never lock an address's live agent token out", %{
      ip: ip,
      scope: scope,
      access_token: device_token
    } do
      {_device, expired} =
        device_with_tokens_fixture(scope, %{}, DateTime.add(DateTime.utc_now(), -2, :hour))

      {:ok, {_api_token, agent_token}} =
        ApiTokens.create_api_token(scope.user, ai_optimized_board_fixture(scope.user), %{
          name: "Agent"
        })

      # More than the 20 failures a minute :api_token allows an address.
      for _ <- 1..30 do
        conn = from_ip(ip, "Bearer " <> expired.access_token)
        assert json_response(conn, 401) == %{"error" => "Invalid access token"}

        assert_received {:telemetry_event, @auth_failed, %{count: 1},
                         %{reason: "device_token_invalid"}}
      end

      agent_conn =
        %{build_conn() | remote_ip: ip}
        |> put_req_header("authorization", "Bearer " <> agent_token)
        |> KanbanWeb.Plugs.AuthenticateApiToken.call([])

      refute agent_conn.halted
      refute from_ip(ip, "Bearer " <> device_token).halted
    end

    test "unknown and malformed tokens still count toward the limit", %{
      ip: ip,
      access_token: token
    } do
      for n <- 1..20 do
        header = if rem(n, 2) == 0, do: "Bearer sdat_unknown#{n}", else: "Bearer"
        assert from_ip(ip, header).status == 401
      end

      assert from_ip(ip, "Bearer " <> token).status == 429
    end

    test "an expired token's 401 is the same as an unknown token's", %{ip: ip, scope: scope} do
      {_device, expired} =
        device_with_tokens_fixture(scope, %{}, DateTime.add(DateTime.utc_now(), -2, :hour))

      unknown = Kanban.Devices.DeviceToken.generate("sdat")
      expired_conn = from_ip(ip, "Bearer " <> expired.access_token)
      unknown_conn = from_ip(ip, "Bearer " <> unknown)

      observable = fn conn ->
        headers = conn.resp_headers |> List.keydelete("x-request-id", 0) |> Enum.sort()
        {conn.status, conn.halted, headers, conn.resp_body}
      end

      assert observable.(expired_conn) == observable.(unknown_conn)

      for _ <- 1..2 do
        assert_received {:telemetry_event, @auth_failed, %{count: 1},
                         %{reason: "device_token_invalid"}}
      end
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
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      assert get_resp_header(conn, "www-authenticate") == [~s(Bearer error="invalid_token")]
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
