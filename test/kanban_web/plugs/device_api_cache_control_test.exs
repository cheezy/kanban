defmodule KanbanWeb.Plugs.DeviceApiCacheControlTest do
  @moduledoc """
  Every `/api/me` response is `private, no-store`, its errors and the
  device plug's refusals included, except a response carrying an `etag`,
  which is `private, max-age=0, must-revalidate` (decided 2026-11-19).
  """
  use KanbanWeb.ConnCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.DevicesFixtures

  alias Kanban.Devices
  alias KanbanWeb.Plugs.DeviceApiCacheControl

  @no_store ["private, no-store"]
  @revalidate ["private, max-age=0, must-revalidate"]

  setup do
    scope = user_scope_fixture()
    {device, issued} = device_with_tokens_fixture(scope)
    %{scope: scope, device: device, token: issued.access_token}
  end

  defp authed(token), do: put_req_header(build_conn(), "authorization", "Bearer " <> token)

  defp cache_control(conn), do: get_resp_header(conn, "cache-control")

  describe "put_cache_control/1" do
    test "is no-store without an etag and revalidate with one" do
      bare = DeviceApiCacheControl.put_cache_control(build_conn())
      assert cache_control(bare) == @no_store

      tagged =
        build_conn()
        |> put_resp_header("etag", ~s("v1"))
        |> DeviceApiCacheControl.put_cache_control()

      assert cache_control(tagged) == @revalidate
    end

    test "replaces whatever cache-control the response had" do
      conn =
        build_conn()
        |> put_resp_header("cache-control", "public, max-age=3600")
        |> DeviceApiCacheControl.put_cache_control()

      assert cache_control(conn) == @no_store
    end
  end

  describe "call/2 as the first plug" do
    test "decides on the headers the response is finally sent with" do
      sent = fn conn ->
        conn
        |> DeviceApiCacheControl.call([])
        |> put_resp_content_type("application/json")
        |> send_resp(200, "{}")
      end

      assert build_conn() |> sent.() |> cache_control() == @no_store

      tagged = build_conn() |> register_before_send(&put_resp_header(&1, "etag", ~s("v1")))

      # A callback registered later runs first, so its etag is seen.
      assert tagged |> DeviceApiCacheControl.call([]) |> sent_with_etag() |> cache_control() ==
               @revalidate

      dropped =
        build_conn()
        |> DeviceApiCacheControl.call([])
        |> register_before_send(&delete_resp_header(&1, "etag"))
        |> put_resp_header("etag", ~s("v1"))
        |> send_resp(200, "{}")

      assert cache_control(dropped) == @no_store
    end
  end

  describe "the router's :device_api pipeline" do
    # Runs the real pipelines and leaves the response to the test, as a
    # review read that sets an etag would.
    defp through_pipeline(token) do
      token
      |> authed()
      |> bypass_through(KanbanWeb.Router, [:api_json, :device_api])
      |> get("/api/me/reviews")
    end

    test "sends a response carrying an etag as revalidate", %{token: token} do
      conn = token |> through_pipeline() |> sent_with_etag()

      assert conn.status == 200
      assert cache_control(conn) == @revalidate
    end

    test "sends a response without one as no-store", %{token: token} do
      conn = token |> through_pipeline() |> send_resp(200, "{}")

      assert cache_control(conn) == @no_store
    end
  end

  describe "with the device plug after it, as in the :device_api pipeline" do
    # A read that sets an etag, as the review reads are meant to.
    defp etagged_read(token) do
      build_conn(:get, "/api/me/reviews")
      |> put_req_header("authorization", "Bearer " <> token)
      |> DeviceApiCacheControl.call([])
      |> KanbanWeb.Plugs.AuthenticateDeviceToken.call([])
    end

    test "a read sent with an etag may be revalidated", %{token: token} do
      conn = token |> etagged_read() |> sent_with_etag()

      assert conn.status == 200
      assert cache_control(conn) == @revalidate
    end

    test "the same read refused in flight drops the etag and is no-store", %{
      scope: scope,
      device: device,
      token: token
    } do
      conn = etagged_read(token)
      {:ok, _} = Devices.revoke_device(scope, device)
      conn = sent_with_etag(conn)

      assert conn.status == 401
      assert get_resp_header(conn, "etag") == []
      assert cache_control(conn) == @no_store
    end
  end

  defp sent_with_etag(conn) do
    conn
    |> put_resp_header("etag", ~s("v1"))
    |> send_resp(200, "{}")
  end

  describe "through the router" do
    test "successful reads and writes are no-store", %{token: token} do
      for conn <- [
            token |> authed() |> get(~p"/api/me"),
            token |> authed() |> get(~p"/api/me/devices"),
            token |> authed() |> get(~p"/api/me/notification_settings"),
            token |> authed() |> get(~p"/api/me/decisions"),
            token |> authed() |> get(~p"/api/me/reviews"),
            token |> authed() |> put(~p"/api/me/devices/current", %{"locale" => "en-GB"})
          ] do
        assert conn.status == 200, conn.request_path
        assert cache_control(conn) == @no_store, conn.request_path
        assert get_resp_header(conn, "etag") == []
      end
    end

    test "a controller's error is no-store", %{token: token} do
      not_found = token |> authed() |> delete(~p"/api/me/devices/999999999")
      assert not_found.status == 404
      assert cache_control(not_found) == @no_store

      invalid = token |> authed() |> put(~p"/api/me/devices/current", %{"locale" => "!!"})
      assert invalid.status == 422
      assert cache_control(invalid) == @no_store
    end

    test "the device plug's refusals are no-store", %{scope: scope, device: device, token: token} do
      missing = get(build_conn(), ~p"/api/me")
      assert missing.status == 401
      assert cache_control(missing) == @no_store

      unknown = "sdat_unknown" |> authed() |> get(~p"/api/me")
      assert json_response(unknown, 401) == %{"error" => "Invalid access token"}
      assert cache_control(unknown) == @no_store

      {:ok, _} = Devices.revoke_device(scope, device)
      revoked = token |> authed() |> get(~p"/api/me")
      assert revoked.status == 401
      assert cache_control(revoked) == @no_store
    end

    test "an outdated app's 426 is no-store", %{token: token} do
      conn =
        token
        |> authed()
        |> put_req_header("x-stride-app", "ios/0.0.1 (1)")
        |> get(~p"/api/me")

      assert conn.status == 426
      assert cache_control(conn) == @no_store
    end

    test "a body that does not parse and a path no route matches are no-store", %{token: token} do
      {400, malformed, _body} =
        assert_error_sent(400, fn ->
          token
          |> authed()
          |> put_req_header("content-type", "application/json")
          |> put(~p"/api/me/devices/current", "{not json")
        end)

      assert {"cache-control", "private, no-store"} in malformed

      unrouted = token |> authed() |> get("/api/me/no-such-route")
      assert unrouted.status == 404
      assert cache_control(unrouted) == @no_store
    end
  end
end

defmodule KanbanWeb.Plugs.DeviceApiCacheControlRateLimitTest do
  # Not async: it turns the global rate limiter on.
  use KanbanWeb.ConnCase, async: false

  setup do
    original = Application.get_env(:kanban, Kanban.RateLimit)
    Application.put_env(:kanban, Kanban.RateLimit, enabled: true, api_token: %{ip_limit: 1})
    on_exit(fn -> Application.put_env(:kanban, Kanban.RateLimit, original) end)
    :ok
  end

  test "the device plug's 429 is no-store" do
    ip = {10, :rand.uniform(255), :rand.uniform(255), :rand.uniform(255)}

    request = fn ->
      %{build_conn() | remote_ip: ip}
      |> put_req_header("authorization", "Bearer sdat_unknown")
      |> get(~p"/api/me")
    end

    assert request.().status == 401
    conn = request.()
    assert conn.status == 429
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
  end
end
