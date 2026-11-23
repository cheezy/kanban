defmodule KanbanWeb.MethodOverrideTest do
  @moduledoc """
  D461: a `_method` field must not change the verb of a request to the JSON
  APIs, while the browser forms that rely on it (`method: :delete` links)
  keep working. The endpoint tests go through the whole plug chain; the plug
  tests pin each path clause of `KanbanWeb.Plugs.MethodOverride`.
  """
  use KanbanWeb.ConnCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.DevicesFixtures

  alias Kanban.Devices
  alias Kanban.Devices.Device
  alias Kanban.Repo
  alias KanbanWeb.Plugs.MethodOverride

  defp json_post(conn, path, body) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp authed(token), do: put_req_header(build_conn(), "authorization", "Bearer " <> token)

  defp signed_in?(device, access_token) do
    is_nil(Repo.get!(Device, device.id).revoked_at) and
      match?({:ok, _}, Devices.fetch_by_access_token(access_token))
  end

  describe "the person API, /api/me" do
    setup do
      scope = user_scope_fixture()
      {device, issued} = device_with_tokens_fixture(scope)
      %{device: device, access_token: issued.access_token}
    end

    test ~s(POST /api/me/devices/current with JSON {"_method":"DELETE"} is not routed as DELETE and the device stays signed in),
         %{device: device, access_token: token} do
      conn = token |> authed() |> json_post("/api/me/devices/current", %{"_method" => "DELETE"})

      assert conn.method == "POST"
      assert conn.status == 404
      assert signed_in?(device, token)
    end

    test "a form-encoded _method body field does not re-verb it either", %{
      device: device,
      access_token: token
    } do
      conn =
        token
        |> authed()
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> post("/api/me/devices/current", "_method=DELETE")

      assert conn.method == "POST"
      assert conn.status == 404
      assert signed_in?(device, token)
    end

    test "a _method in the query string does not re-verb it", %{
      device: device,
      access_token: token
    } do
      conn = token |> authed() |> json_post("/api/me/devices/current?_method=DELETE", %{})

      assert conn.method == "POST"
      assert conn.status == 404
      assert signed_in?(device, token)
    end

    test "a percent-encoded /api prefix does not re-verb it either", %{
      device: device,
      access_token: token
    } do
      conn = token |> authed() |> json_post("/%61pi/me/devices/current", %{"_method" => "DELETE"})

      assert conn.method == "POST"
      assert conn.status == 404
      assert signed_in?(device, token)
    end

    test "the declared DELETE still signs the device out", %{device: device, access_token: token} do
      conn =
        token
        |> authed()
        |> put_req_header("accept", "application/json")
        |> delete(~p"/api/me/devices/current")

      assert conn.status == 204
      refute signed_in?(device, token)
    end
  end

  describe "the device sign-in endpoints, /oauth" do
    test "POST /oauth/revoke with a _method body field is not re-verbed" do
      scope = user_scope_fixture()
      {device, issued} = device_with_tokens_fixture(scope)

      conn =
        json_post(build_conn(), "/oauth/revoke", %{
          "_method" => "DELETE",
          "token" => issued.refresh_token,
          "client_id" => "stride-ios"
        })

      assert conn.method == "POST"
      assert json_response(conn, 200) == %{}
      assert %DateTime{} = Repo.get!(Device, device.id).revoked_at
    end
  end

  describe "browser forms" do
    test "a browser form POST with _method=delete still reaches the DELETE route", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> log_in_user(user)
        |> post(~p"/users/log-out", %{"_method" => "delete"})

      assert conn.method == "DELETE"
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
    end
  end

  describe "KanbanWeb.Plugs.MethodOverride" do
    @opts MethodOverride.init([])

    defp override(path, method \\ :post) do
      method
      |> Plug.Test.conn(path, %{"_method" => "DELETE"})
      |> MethodOverride.call(@opts)
    end

    test "leaves every machine API path a POST" do
      for path <- [
            "/api/me/devices/current",
            "/api/tasks/1/complete",
            "/api/mcp",
            "/scim/v2/Users/1",
            "/oauth/token",
            "/oauth/revoke",
            "/.well-known/stride-audit-signing-keys"
          ] do
        assert override(path).method == "POST", "#{path} was re-verbed"
      end
    end

    test "still overrides the browser paths, /oauth/authorize included" do
      for path <- ["/users/log-out", "/boards/1", "/oauth/authorize", "/oauth/token/extra"] do
        assert override(path).method == "DELETE", "#{path} was not re-verbed"
      end
    end

    test "only overrides a POST, as Plug.MethodOverride does" do
      assert override("/users/log-out", :put).method == "PUT"
    end

    test "a path that only starts with an API prefix is a browser path" do
      assert override("/apis").method == "DELETE"
      assert override("/oauthx/token").method == "DELETE"
    end

    test "matches the decoded segments, as the router does" do
      for path <- [
            "/%61pi/tasks/1",
            "/sc%69m/v2/Users/1",
            "/%6Fauth/revok%65",
            "/%2Ewell-known/x"
          ] do
        assert override(path).method == "POST", "#{path} was re-verbed"
      end

      assert override("/users/log-o%75t").method == "DELETE"
    end

    test "a segment that is not valid percent-encoding is compared undecoded" do
      assert override("/api/%zz").method == "POST"
      assert override("/%zz/log-out").method == "DELETE"
    end
  end
end
