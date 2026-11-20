defmodule KanbanWeb.OAuthTokenControllerTest do
  use KanbanWeb.ConnCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.DevicesFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.AuditLog
  alias Kanban.Devices
  alias Kanban.Devices.Device
  alias Kanban.Devices.DeviceToken
  alias Kanban.Repo

  setup %{conn: conn} do
    scope = user_scope_fixture()
    %{conn: put_req_header(conn, "accept", "application/json"), scope: scope}
  end

  defp code_params(code, overrides \\ %{}) do
    Map.merge(
      %{
        "grant_type" => "authorization_code",
        "client_id" => code.client_id,
        "code" => code.code,
        "code_verifier" => valid_code_verifier(),
        "redirect_uri" => code.redirect_uri,
        "platform" => "ios",
        "device_class" => "phone",
        "model" => "iPhone15,2",
        "os_version" => "18.1",
        "app_version" => "1.0.0 (42)",
        "locale" => "en-GB",
        "time_zone" => "Europe/London",
        "approval_public_key" => valid_approval_public_key()
      },
      overrides
    )
  end

  defp refresh_params(refresh_token) do
    %{
      "grant_type" => "refresh_token",
      "client_id" => "stride-ios",
      "refresh_token" => refresh_token
    }
  end

  defp revoke_params(token), do: %{"token" => token, "client_id" => "stride-ios"}

  defp device_count, do: Repo.aggregate(Device, :count)

  defp assert_oauth_error(conn, error) do
    assert %{"error" => ^error, "error_description" => description} = json_response(conn, 400)
    assert is_binary(description)
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    refute conn |> json_response(400) |> Map.has_key?("refresh_token")
    description
  end

  describe "POST /oauth/token, authorization_code" do
    test "exchanges a valid code and verifier for tokens and creates the device", %{
      conn: conn,
      scope: scope
    } do
      code = authorization_code_fixture(scope, %{device_name: "Ana's iPhone"})
      key = valid_approval_public_key()

      conn = post(conn, ~p"/oauth/token", code_params(code, %{"approval_public_key" => key}))

      assert %{
               "access_token" => "sdat_" <> _ = access_token,
               "refresh_token" => "sdrt_" <> _ = refresh_token,
               "token_type" => "Bearer",
               "expires_in" => 3600
             } = json_response(conn, 200)

      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "pragma") == ["no-cache"]

      assert {:ok, device} = Devices.fetch_by_access_token(access_token)
      assert device.user_id == scope.user.id
      assert device.name == "Ana's iPhone"
      assert device.client_id == "stride-ios"
      assert device.platform == :ios
      assert device.device_class == :phone
      assert device.approval_public_key == key

      assert Repo.get_by!(DeviceToken, token_hash: DeviceToken.hash_token(refresh_token)).kind ==
               :refresh
    end

    test "accepts the same request as a JSON body", %{conn: conn, scope: scope} do
      code = authorization_code_fixture(scope)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/oauth/token", code |> code_params() |> Jason.encode!())

      assert %{"token_type" => "Bearer"} = json_response(conn, 200)
    end

    test "refuses a PKCE mismatch, a reused code, an expired code and a wrong redirect URI", %{
      conn: conn,
      scope: scope
    } do
      mismatch = authorization_code_fixture(scope)
      wrong_verifier = String.duplicate("x", 43)

      conn
      |> post(~p"/oauth/token", code_params(mismatch, %{"code_verifier" => wrong_verifier}))
      |> assert_oauth_error("invalid_grant")

      # The mismatch used the code up: the right verifier no longer works.
      conn |> post(~p"/oauth/token", code_params(mismatch)) |> assert_oauth_error("invalid_grant")

      reused = authorization_code_fixture(scope)
      assert %{} = conn |> post(~p"/oauth/token", code_params(reused)) |> json_response(200)
      conn |> post(~p"/oauth/token", code_params(reused)) |> assert_oauth_error("invalid_grant")

      issued_at = DateTime.add(DateTime.utc_now(), -61, :second)
      expired = authorization_code_fixture(scope, %{}, issued_at)
      conn |> post(~p"/oauth/token", code_params(expired)) |> assert_oauth_error("invalid_grant")

      redirect = authorization_code_fixture(scope)
      other_uri = %{"redirect_uri" => "com.stridelikeaboss.app:/elsewhere"}

      conn
      |> post(~p"/oauth/token", code_params(redirect, other_uri))
      |> assert_oauth_error("invalid_grant")

      other_client = authorization_code_fixture(scope)

      conn
      |> post(~p"/oauth/token", code_params(other_client, %{"client_id" => "stride-android"}))
      |> assert_oauth_error("invalid_grant")

      assert device_count() == 1
    end

    test "a missing grant_type or device details answers invalid_request", %{
      conn: conn,
      scope: scope
    } do
      code = authorization_code_fixture(scope)
      params = code_params(code)

      conn
      |> post(~p"/oauth/token", Map.delete(params, "grant_type"))
      |> assert_oauth_error("invalid_request")

      for field <- ~w(code code_verifier redirect_uri client_id) do
        conn
        |> post(~p"/oauth/token", Map.delete(params, field))
        |> assert_oauth_error("invalid_request")
      end

      conn
      |> post(~p"/oauth/token", Map.put(params, "code", [code.code]))
      |> assert_oauth_error("invalid_request")

      for field <- ~w(platform device_class approval_public_key) do
        description =
          conn
          |> post(~p"/oauth/token", Map.delete(params, field))
          |> assert_oauth_error("invalid_request")

        assert description =~ field
      end

      <<4, x::binary-size(32), y::unsigned-big-256>> =
        params["approval_public_key"] |> Base.url_decode64!(padding: false)

      off_curve = Base.url_encode64(<<4, x::binary, y + 1::unsigned-big-256>>, padding: false)
      compressed = Base.url_encode64(<<2 + rem(y, 2), x::binary>>, padding: false)

      for key <- [off_curve, compressed, "fixture-public-key", Base.encode64("not a key")] do
        description =
          conn
          |> post(~p"/oauth/token", Map.put(params, "approval_public_key", key))
          |> assert_oauth_error("invalid_request")

        assert description =~ "approval_public_key"
        refute description =~ key
      end

      # None of the refusals above used the code up.
      assert %{} = conn |> post(~p"/oauth/token", params) |> json_response(200)
    end

    test "an unknown grant type or client is refused", %{conn: conn, scope: scope} do
      params = code_params(authorization_code_fixture(scope))

      conn
      |> post(~p"/oauth/token", Map.put(params, "grant_type", "password"))
      |> assert_oauth_error("unsupported_grant_type")

      conn
      |> post(~p"/oauth/token", Map.put(params, "client_id", "stride-web"))
      |> assert_oauth_error("invalid_client")

      assert device_count() == 0
    end

    test "writes device_signed_in with platform, device_class and app_version", %{
      conn: conn,
      scope: scope
    } do
      org = organization_fixture()
      organization_member_fixture(org, scope.user)
      code = authorization_code_fixture(scope)

      params = code_params(code, %{"platform" => "android", "device_class" => "tablet"})

      %{"access_token" => access_token} =
        conn |> post(~p"/oauth/token", params) |> json_response(200)

      {:ok, device} = Devices.fetch_by_access_token(access_token)

      assert [event] =
               AuditLog.list_events(action: "device_signed_in", actor_user_id: scope.user.id)

      assert event.organization_id == org.id
      assert event.ip == "127.0.0.1"

      assert event.metadata["device_id"] == device.id
      assert event.metadata["platform"] == "android"
      assert event.metadata["device_class"] == "tablet"
      assert event.metadata["app_version"] == "1.0.0 (42)"

      stored = Jason.encode!(event.metadata)
      refute stored =~ access_token
      refute stored =~ params["approval_public_key"]
      refute stored =~ code.code
    end
  end

  describe "POST /oauth/token, refresh_token" do
    test "refresh rotates and the old refresh token is refused", %{conn: conn, scope: scope} do
      {device, issued} = device_with_tokens_fixture(scope)

      assert %{"refresh_token" => rotated, "access_token" => access_token, "expires_in" => 3600} =
               conn
               |> post(~p"/oauth/token", refresh_params(issued.refresh_token))
               |> json_response(200)

      assert rotated != issued.refresh_token
      assert {:ok, %Device{id: id}} = Devices.fetch_by_access_token(access_token)
      assert id == device.id

      conn
      |> post(~p"/oauth/token", refresh_params(issued.refresh_token))
      |> assert_oauth_error("invalid_grant")
    end

    test "the rotated refresh token works once more", %{conn: conn, scope: scope} do
      {_device, issued} = device_with_tokens_fixture(scope)

      %{"refresh_token" => rotated} =
        conn |> post(~p"/oauth/token", refresh_params(issued.refresh_token)) |> json_response(200)

      assert %{"refresh_token" => next} =
               conn |> post(~p"/oauth/token", refresh_params(rotated)) |> json_response(200)

      assert next != rotated
    end

    test "a refresh token works only for the client it was issued to", %{
      conn: conn,
      scope: scope
    } do
      {_device, issued} = device_with_tokens_fixture(scope, %{client_id: "stride-ios"})
      android = issued.refresh_token |> refresh_params() |> Map.put("client_id", "stride-android")

      conn
      |> post(~p"/oauth/token", android)
      |> assert_oauth_error("invalid_grant")

      assert %{"refresh_token" => _rotated} =
               conn
               |> post(~p"/oauth/token", refresh_params(issued.refresh_token))
               |> json_response(200)
    end

    test "reuse revokes the device and writes device_refresh_reuse_detected", %{
      conn: conn,
      scope: scope
    } do
      {device, issued} = device_with_tokens_fixture(scope)

      %{"refresh_token" => rotated, "access_token" => access_token} =
        conn |> post(~p"/oauth/token", refresh_params(issued.refresh_token)) |> json_response(200)

      conn
      |> post(~p"/oauth/token", refresh_params(issued.refresh_token))
      |> assert_oauth_error("invalid_grant")

      assert %DateTime{} = Repo.get!(Device, device.id).revoked_at
      assert Devices.fetch_by_access_token(access_token) == {:error, :invalid_token}

      conn
      |> post(~p"/oauth/token", refresh_params(rotated))
      |> assert_oauth_error("invalid_grant")

      assert [event] =
               AuditLog.list_events(
                 action: "device_refresh_reuse_detected",
                 actor_user_id: scope.user.id
               )

      assert event.metadata["device_id"] == device.id
      refute Jason.encode!(event.metadata) =~ issued.refresh_token
    end

    test "an unknown, missing or access token is refused with invalid_grant or invalid_request",
         %{conn: conn, scope: scope} do
      {_device, issued} = device_with_tokens_fixture(scope)

      conn
      |> post(~p"/oauth/token", refresh_params("sdrt_not-a-real-token"))
      |> assert_oauth_error("invalid_grant")

      conn
      |> post(~p"/oauth/token", refresh_params(issued.access_token))
      |> assert_oauth_error("invalid_grant")

      conn
      |> post(~p"/oauth/token", %{"grant_type" => "refresh_token", "client_id" => "stride-ios"})
      |> assert_oauth_error("invalid_request")
    end
  end

  describe "POST /oauth/revoke" do
    test "revoke takes the refresh token in the body and kills the device's tokens", %{
      conn: conn,
      scope: scope
    } do
      {device, issued} = device_with_tokens_fixture(scope)

      assert conn
             |> post(~p"/oauth/revoke", revoke_params(issued.refresh_token))
             |> json_response(200) ==
               %{}

      revoked = Repo.get!(Device, device.id)
      assert %DateTime{} = revoked.revoked_at
      assert revoked.revoked_by_id == scope.user.id
      assert Devices.fetch_by_access_token(issued.access_token) == {:error, :invalid_token}

      conn
      |> post(~p"/oauth/token", refresh_params(issued.refresh_token))
      |> assert_oauth_error("invalid_grant")
    end

    test "a bearer header is never read and the token must be in the body", %{
      conn: conn,
      scope: scope
    } do
      {device, issued} = device_with_tokens_fixture(scope)

      conn
      |> put_req_header("authorization", "Bearer " <> issued.refresh_token)
      |> post(~p"/oauth/revoke", %{"client_id" => "stride-ios"})
      |> assert_oauth_error("invalid_request")

      conn
      |> put_req_header("authorization", "Bearer " <> issued.access_token)
      |> post(~p"/oauth/revoke", %{"client_id" => "stride-ios"})
      |> assert_oauth_error("invalid_request")

      assert is_nil(Repo.get!(Device, device.id).revoked_at)
    end

    test "a token in the query string is never read", %{conn: conn, scope: scope} do
      {device, issued} = device_with_tokens_fixture(scope)
      query = issued.refresh_token |> revoke_params() |> URI.encode_query()

      conn
      |> post("/oauth/revoke?" <> query, %{})
      |> assert_oauth_error("invalid_request")

      assert is_nil(Repo.get!(Device, device.id).revoked_at)
    end

    test "an unknown or already revoked token answers 200 and changes nothing", %{
      conn: conn,
      scope: scope
    } do
      {device, issued} = device_with_tokens_fixture(scope)

      assert conn |> post(~p"/oauth/revoke", revoke_params("sdrt_unknown")) |> json_response(200) ==
               %{}

      assert conn
             |> post(~p"/oauth/revoke", revoke_params(issued.access_token))
             |> json_response(200) ==
               %{}

      assert is_nil(Repo.get!(Device, device.id).revoked_at)

      conn
      |> post(~p"/oauth/revoke", %{"token" => issued.refresh_token, "client_id" => "x"})
      |> assert_oauth_error("invalid_client")

      assert is_nil(Repo.get!(Device, device.id).revoked_at)
    end
  end

  describe "the :oauth pipeline" do
    test "a code, verifier or refresh token in the query string is never read", %{
      conn: conn,
      scope: scope
    } do
      code = authorization_code_fixture(scope)
      params = code_params(code)
      in_query = Map.take(params, ~w(code code_verifier redirect_uri))

      body = Map.drop(params, Map.keys(in_query))

      conn
      |> post("/oauth/token?" <> URI.encode_query(in_query), body)
      |> assert_oauth_error("invalid_request")

      assert device_count() == 0

      {_device, issued} = device_with_tokens_fixture(scope)
      query = URI.encode_query(%{"refresh_token" => issued.refresh_token})

      conn
      |> post("/oauth/token?" <> query, %{
        "grant_type" => "refresh_token",
        "client_id" => "stride-ios"
      })
      |> assert_oauth_error("invalid_request")

      assert %{"refresh_token" => _rotated} =
               conn
               |> post(~p"/oauth/token", refresh_params(issued.refresh_token))
               |> json_response(200)
    end

    test "GET /oauth/token and GET /oauth/revoke answer 404, never a token", %{conn: conn} do
      for path <- ["/oauth/token", "/oauth/revoke"] do
        conn = get(conn, path)

        assert conn.status == 404
        refute conn.resp_body =~ "access_token"
      end
    end

    test "a malformed body answers a JSON invalid_request" do
      for path <- ["/oauth/token", "/oauth/revoke"] do
        {400, headers, body} =
          assert_error_sent(400, fn ->
            build_conn()
            |> put_req_header("accept", "*/*")
            |> put_req_header("content-type", "application/json")
            |> post(path, "{not json")
          end)

        assert {"content-type", "application/json; charset=utf-8"} in headers
        assert {"cache-control", "no-store"} in headers
        assert {"pragma", "no-cache"} in headers

        assert Jason.decode!(body) == %{
                 "error" => "invalid_request",
                 "error_description" => "The request is malformed and could not be processed."
               }
      end
    end

    test "a body in a content type that is not parsed answers invalid_request, never a 500", %{
      conn: conn
    } do
      for path <- ["/oauth/token", "/oauth/revoke"],
          type <- ["text/plain", "application/xml", "application/octet-stream"] do
        conn
        |> put_req_header("content-type", type)
        |> post(path, "token=sdrt_anything&client_id=stride-ios")
        |> assert_oauth_error("invalid_request")
      end
    end

    test "a request that accepts no JSON answers 406 and is still not stored" do
      for path <- ["/oauth/token", "/oauth/revoke"] do
        {406, headers, _body} =
          assert_error_sent(406, fn ->
            build_conn()
            |> put_req_header("accept", "text/html")
            |> post(path, %{})
          end)

        assert {"cache-control", "no-store"} in headers
        assert {"pragma", "no-cache"} in headers
      end
    end

    test "an API token is not accepted as a refresh token", %{conn: conn} do
      conn
      |> post(~p"/oauth/token", refresh_params("stride_dev_not-a-device-token"))
      |> assert_oauth_error("invalid_grant")
    end
  end
end

defmodule KanbanWeb.OAuthTokenControllerRateLimitTest do
  # Not async: it turns the global rate limiter on with small limits.
  use KanbanWeb.ConnCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.DevicesFixtures

  setup do
    original = Application.get_env(:kanban, Kanban.RateLimit)

    Application.put_env(:kanban, Kanban.RateLimit,
      enabled: true,
      oauth_token: %{scale_ms: 60_000, ip_limit: 2},
      oauth_revoke: %{scale_ms: 60_000, ip_limit: 2},
      oauth_device: %{scale_ms: 60_000, id_limit: 1}
    )

    on_exit(fn -> Application.put_env(:kanban, Kanban.RateLimit, original) end)

    %{ip: {10, :rand.uniform(255), :rand.uniform(255), :rand.uniform(255)}}
  end

  defp from_ip(ip),
    do: %{build_conn() | remote_ip: ip} |> put_req_header("accept", "application/json")

  defp random_ip, do: {10, :rand.uniform(255), :rand.uniform(255), :rand.uniform(255)}

  test "rate limits repeated token requests per IP", %{ip: ip} do
    # A different token each time, so only the IP ceiling is reached.
    params = fn n ->
      %{"grant_type" => "refresh_token", "client_id" => "stride-ios", "refresh_token" => "x#{n}"}
    end

    for attempt <- 1..2 do
      assert %{"error" => "invalid_grant"} =
               ip |> from_ip() |> post(~p"/oauth/token", params.(attempt)) |> json_response(400)
    end

    conn = ip |> from_ip() |> post(~p"/oauth/token", params.(3))

    assert %{"error" => "rate_limited"} = json_response(conn, 429)
    assert [retry_after] = get_resp_header(conn, "retry-after")
    assert String.to_integer(retry_after) > 0
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    revoke = fn n -> %{"token" => "revoke-#{n}", "client_id" => "stride-ios"} end

    for attempt <- 1..2 do
      assert ip |> from_ip() |> post(~p"/oauth/revoke", revoke.(attempt)) |> json_response(200)
    end

    assert %{"error" => "rate_limited"} =
             ip |> from_ip() |> post(~p"/oauth/revoke", revoke.(3)) |> json_response(429)

    # Another address is not affected.
    assert %{"error" => "invalid_grant"} =
             random_ip() |> from_ip() |> post(~p"/oauth/token", params.(4)) |> json_response(400)
  end

  test "rate limits refresh and revoke per presented token across addresses" do
    {_device, issued} = device_with_tokens_fixture(user_scope_fixture())

    refresh = fn token ->
      %{"grant_type" => "refresh_token", "client_id" => "stride-ios", "refresh_token" => token}
    end

    assert %{"refresh_token" => rotated} =
             random_ip()
             |> from_ip()
             |> post(~p"/oauth/token", refresh.(issued.refresh_token))
             |> json_response(200)

    # The used token again, from another address: its budget is spent, so it
    # is refused before it is looked at.
    assert %{"error" => "rate_limited"} =
             random_ip()
             |> from_ip()
             |> post(~p"/oauth/token", refresh.(issued.refresh_token))
             |> json_response(429)

    # The device's new token has a budget of its own.
    assert %{"refresh_token" => _next} =
             random_ip()
             |> from_ip()
             |> post(~p"/oauth/token", refresh.(rotated))
             |> json_response(200)

    revoke = %{"token" => rotated, "client_id" => "stride-ios"}

    assert %{"error" => "rate_limited"} =
             random_ip() |> from_ip() |> post(~p"/oauth/revoke", revoke) |> json_response(429)
  end

  describe "an unknown and a revoked refresh token" do
    setup do
      Application.put_env(:kanban, Kanban.RateLimit,
        enabled: true,
        oauth_token: %{scale_ms: 60_000, ip_limit: 1_000},
        oauth_revoke: %{scale_ms: 60_000, ip_limit: 1_000},
        oauth_device: %{scale_ms: 60_000, id_limit: 3}
      )

      scope = user_scope_fixture()
      {device, issued} = device_with_tokens_fixture(scope)
      {:ok, _revoked} = Kanban.Devices.revoke_device(scope, device)

      # A fresh token of the same shape that was never issued, so only
      # whether it was ever real differs.
      unknown = Kanban.Devices.DeviceToken.generate("sdrt")
      assert String.length(unknown) == String.length(issued.refresh_token)

      %{revoked: issued.refresh_token, unknown: unknown}
    end

    test "answer refresh attempts identically, the 429 at the limit included", %{
      ip: ip,
      revoked: revoked,
      unknown: unknown
    } do
      refresh = fn token ->
        %{"grant_type" => "refresh_token", "client_id" => "stride-ios", "refresh_token" => token}
      end

      for attempt <- 1..5 do
        unknown_conn = ip |> from_ip() |> post(~p"/oauth/token", refresh.(unknown))
        revoked_conn = ip |> from_ip() |> post(~p"/oauth/token", refresh.(revoked))

        assert observable(unknown_conn) == observable(revoked_conn)
        assert_retry_after_alike(unknown_conn, revoked_conn)
        assert unknown_conn.status == if(attempt <= 3, do: 400, else: 429)
      end
    end

    test "answer revoke attempts identically, the 429 at the limit included", %{
      ip: ip,
      revoked: revoked,
      unknown: unknown
    } do
      revoke = fn token -> %{"token" => token, "client_id" => "stride-ios"} end

      for attempt <- 1..5 do
        unknown_conn = ip |> from_ip() |> post(~p"/oauth/revoke", revoke.(unknown))
        revoked_conn = ip |> from_ip() |> post(~p"/oauth/revoke", revoke.(revoked))

        assert observable(unknown_conn) == observable(revoked_conn)
        assert_retry_after_alike(unknown_conn, revoked_conn)
        assert unknown_conn.status == if(attempt <= 3, do: 200, else: 429)
      end
    end
  end

  # Everything a client sees except the per-request id and the retry-after
  # count, which reads the clock and is compared by assert_retry_after_alike/2.
  defp observable(conn) do
    headers =
      conn.resp_headers
      |> Enum.reject(fn {name, _value} -> name in ["x-request-id", "retry-after"] end)
      |> Enum.sort()

    {conn.status, headers, conn.resp_body}
  end

  defp assert_retry_after_alike(left, right) do
    case {get_resp_header(left, "retry-after"), get_resp_header(right, "retry-after")} do
      {[], []} -> :ok
      {[a], [b]} -> assert abs(String.to_integer(a) - String.to_integer(b)) <= 1
    end
  end
end
