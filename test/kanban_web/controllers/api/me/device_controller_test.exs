defmodule KanbanWeb.API.Me.DeviceControllerTest do
  # async: false - one test switches the global :plans_enforced application env on.
  use KanbanWeb.ConnCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.DevicesFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TelemetryHelpers

  alias Kanban.ApiTokens
  alias Kanban.AuditLog
  alias Kanban.Devices
  alias Kanban.Devices.Device
  alias Kanban.Repo

  setup do
    user = user_fixture()
    scope = user_scope_fixture(user)
    {device, issued} = device_with_tokens_fixture(scope, %{name: "Ada's iPhone"})

    %{user: user, scope: scope, device: device, access_token: issued.access_token}
  end

  defp authed(token) do
    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp list(token), do: token |> authed() |> get(~p"/api/me/devices")
  defp sign_out(token), do: token |> authed() |> delete(~p"/api/me/devices/current")
  defp revoke(token, id), do: token |> authed() |> delete("/api/me/devices/#{id}")
  defp update(token, body), do: token |> authed() |> put(~p"/api/me/devices/current", body)

  defp revoked_events(user_id),
    do: AuditLog.list_events(action: "device_revoked", actor_user_id: user_id)

  describe "GET /api/me/devices" do
    test "lists only the signed-in person's devices", ctx do
      tablet = device_fixture(ctx.scope, %{name: "Ada's iPad", device_class: :tablet})
      revoked = device_fixture(ctx.scope, %{name: "Old phone"})
      {:ok, _} = Devices.revoke_device(ctx.scope, revoked)
      device_fixture(user_scope_fixture(), %{name: "Someone else's phone"})

      data = ctx.access_token |> list() |> json_response(200) |> Map.fetch!("data")

      assert data |> Enum.map(& &1["id"]) |> Enum.sort() == Enum.sort([ctx.device.id, tablet.id])

      current = Enum.find(data, &(&1["id"] == ctx.device.id))
      other = Enum.find(data, &(&1["id"] == tablet.id))

      assert current["current"] == true
      assert other["current"] == false
      assert current["name"] == "Ada's iPhone"
      assert current["platform"] == "ios"
      assert current["time_zone"] == "Europe/London"
      assert current["push_registered"] == false
    end

    test "never renders a token, a hash or the approval key", ctx do
      {:ok, _} =
        Devices.update_current(ctx.scope, ctx.device, %{"push_token" => "fixture-push-token-list"})

      body = ctx.access_token |> list() |> response(200)

      refute body =~ "fixture-push-token-list"
      refute body =~ ctx.device.approval_public_key
      refute body =~ ctx.access_token

      [device] = Jason.decode!(body)["data"]
      assert device["push_registered"] == true

      refute device |> Map.keys() |> Enum.any?(&(&1 =~ ~r/hash|approval|push_token/))
    end

    test "an agent API token is refused", ctx do
      {:ok, {_api_token, agent_token}} =
        ApiTokens.create_api_token(ctx.user, ai_optimized_board_fixture(ctx.user), %{
          name: "Agent"
        })

      for conn <- [list(agent_token), sign_out(agent_token), revoke(agent_token, ctx.device.id)] do
        assert json_response(conn, 401)
      end

      assert is_nil(Repo.get!(Device, ctx.device.id).revoked_at)
    end

    test "is not plan-gated: a free user lists and signs out with plans enforced", ctx do
      enforce_plans()

      assert [%{"id" => id}] = ctx.access_token |> list() |> json_response(200) |> Map.get("data")
      assert id == ctx.device.id
      assert ctx.access_token |> sign_out() |> response(204)
    end
  end

  describe "DELETE /api/me/devices/current" do
    test "DELETE current revokes this device and later calls answer 401", ctx do
      assert ctx.access_token |> sign_out() |> response(204) == ""

      assert %DateTime{} = Repo.get!(Device, ctx.device.id).revoked_at

      assert ctx.access_token |> list() |> json_response(401) == %{
               "error" => "Invalid access token"
             }

      assert [event] = revoked_events(ctx.user.id)
      assert event.metadata["reason"] == "sign_out"
    end

    test "revoking one device leaves the person's other device signed in", ctx do
      {other, other_issued} = device_with_tokens_fixture(ctx.scope, %{name: "Ada's iPad"})

      assert ctx.access_token |> sign_out() |> response(204)

      assert [%{"id" => id, "current" => true}] =
               other_issued.access_token |> list() |> json_response(200) |> Map.get("data")

      assert id == other.id
      assert is_nil(Repo.get!(Device, other.id).revoked_at)
    end
  end

  describe "DELETE /api/me/devices/:id" do
    test "revokes another of the person's devices, which then answers 401", ctx do
      {other, other_issued} = device_with_tokens_fixture(ctx.scope, %{name: "Ada's iPad"})

      assert ctx.access_token |> revoke(other.id) |> response(204)

      assert other_issued.access_token |> list() |> json_response(401)
      assert [%{"id" => id}] = ctx.access_token |> list() |> json_response(200) |> Map.get("data")
      assert id == ctx.device.id

      assert [event] = revoked_events(ctx.user.id)
      assert event.metadata["reason"] == "user"
      assert event.metadata["device_id"] == other.id
    end

    test "cannot revoke another person's device (404)", ctx do
      {theirs, their_issued} = device_with_tokens_fixture(user_scope_fixture())

      assert ctx.access_token |> revoke(theirs.id) |> json_response(404) == %{
               "error" => "Not Found"
             }

      assert is_nil(Repo.get!(Device, theirs.id).revoked_at)
      assert their_issued.access_token |> list() |> json_response(200)
      assert revoked_events(ctx.user.id) == []
    end

    test "an id that is not a device id answers the same 404", ctx do
      missing = ctx.device.id + 1_000_000

      for id <- ["abc", "1.5", "-1", "0", "99999999999999999999", missing] do
        assert ctx.access_token |> revoke(id) |> json_response(404) == %{"error" => "Not Found"},
               "expected 404 for #{inspect(id)}"
      end
    end

    test "revoking an already revoked device answers 204 and records it once", ctx do
      other = device_fixture(ctx.scope, %{name: "Ada's iPad"})

      assert ctx.access_token |> revoke(other.id) |> response(204)
      assert ctx.access_token |> revoke(other.id) |> response(204)

      assert [_one] = revoked_events(ctx.user.id)
    end

    test "writes device_revoked and emits the revoked telemetry", ctx do
      org = organization_fixture()
      organization_member_fixture(org, ctx.user)
      other = device_fixture(ctx.scope, %{name: "Ada's iPad", platform: :android})
      attach_telemetry([:kanban, :device, :revoked])

      assert ctx.access_token |> revoke(other.id) |> response(204)

      assert_receive {:telemetry_event, [:kanban, :device, :revoked], %{count: 1}, metadata}
      assert metadata == %{platform: "android", reason: :user}

      assert [event] = revoked_events(ctx.user.id)
      assert event.actor_user_id == ctx.user.id
      assert event.organization_id == org.id
      assert event.ip == "127.0.0.1"

      assert event.metadata == %{
               "user_id" => ctx.user.id,
               "organization_id" => org.id,
               "device_id" => other.id,
               "device_user_id" => ctx.user.id,
               "reason" => "user",
               "ip" => "127.0.0.1"
             }
    end
  end

  describe "PUT /api/me/devices/current" do
    test "PUT current updates push token, locale, time zone and app version", ctx do
      body = %{
        "push_token" => "fixture-push-token-put",
        "push_environment" => "sandbox",
        "locale" => "fr_FR",
        "time_zone" => "America/New_York",
        "app_version" => "1.1.0 (50)",
        "name" => "Renamed",
        "platform" => "android"
      }

      data = ctx.access_token |> update(body) |> json_response(200) |> Map.fetch!("data")

      assert data["id"] == ctx.device.id
      assert data["current"] == true
      assert data["push_registered"] == true
      assert data["push_environment"] == "sandbox"
      assert data["locale"] == "fr_FR"
      assert data["time_zone"] == "America/New_York"
      assert data["app_version"] == "1.1.0 (50)"
      refute Map.has_key?(data, "push_token")

      stored = Repo.get!(Device, ctx.device.id)
      assert stored.push_token == "fixture-push-token-put"
      assert stored.push_environment == :sandbox
      # Fields the app may not change are ignored.
      assert stored.name == "Ada's iPhone"
      assert stored.platform == :ios

      # An empty push token clears it; a key not sent is left as it is.
      cleared =
        ctx.access_token
        |> update(%{"push_token" => ""})
        |> json_response(200)
        |> Map.fetch!("data")

      assert cleared["push_registered"] == false
      assert cleared["time_zone"] == "America/New_York"
      assert is_nil(Repo.get!(Device, ctx.device.id).push_token)
    end

    test "a push token already on another device moves to this one", ctx do
      old = device_fixture(ctx.scope, %{name: "Same phone, old sign-in"})

      {:ok, _} =
        Devices.update_current(ctx.scope, old, %{"push_token" => "fixture-push-token-move"})

      theirs = device_fixture(user_scope_fixture(), %{name: "Someone else's"})

      assert ctx.access_token
             |> update(%{"push_token" => "fixture-push-token-move"})
             |> json_response(200)

      assert Repo.get!(Device, ctx.device.id).push_token == "fixture-push-token-move"
      assert is_nil(Repo.get!(Device, old.id).push_token)
      assert is_nil(Repo.get!(Device, theirs.id).push_token)
    end

    test "answers 422 for a push token another person's device holds and moves nothing", ctx do
      theirs =
        device_fixture(user_scope_fixture(), %{
          name: "Someone else's",
          push_token: "fixture-push-token-theirs"
        })

      body =
        ctx.access_token
        |> update(%{"push_token" => "fixture-push-token-theirs"})
        |> json_response(422)

      assert body == %{"errors" => %{"push_token" => ["has already been taken"]}}
      assert Repo.get!(Device, theirs.id).push_token == "fixture-push-token-theirs"
      assert is_nil(Repo.get!(Device, ctx.device.id).push_token)
    end

    test "rejects an unknown push_environment or an invalid time zone", ctx do
      assert %{"errors" => %{"push_environment" => [_]}} =
               ctx.access_token
               |> update(%{"push_environment" => "staging"})
               |> json_response(422)

      assert %{"errors" => %{"time_zone" => ["is not a known time zone"]}} =
               ctx.access_token
               |> update(%{"time_zone" => "Mars/Olympus_Mons"})
               |> json_response(422)

      assert %{"errors" => %{"locale" => [_]}} =
               ctx.access_token |> update(%{"locale" => "not a locale"}) |> json_response(422)

      body =
        ctx.access_token
        |> update(%{"push_token" => "fixture-push-token-bad", "time_zone" => "Nope/Nowhere"})
        |> response(422)

      refute body =~ "fixture-push-token-bad"
      refute body =~ "Nope/Nowhere"

      stored = Repo.get!(Device, ctx.device.id)
      assert stored.time_zone == "Europe/London"
      assert is_nil(stored.push_token)
    end
  end

  describe "a device revoked while its own request is in flight (W2748)" do
    setup ctx do
      other = device_fixture(ctx.scope, %{name: "Ada's iPad"})
      %{other: other}
    end

    # Runs the route's pipelines, so the device is authenticated, then
    # revokes it, then runs the action on that same conn.
    defp in_flight(ctx, method, path, action, params) do
      conn =
        ctx.access_token
        |> authed()
        |> bypass_through(KanbanWeb.Router, [:api_json, :device_api])
        |> dispatch(KanbanWeb.Endpoint, method, path)

      assert conn.assigns.current_device.id == ctx.device.id
      {:ok, _revoked} = Devices.revoke_device(ctx.scope, ctx.device)

      conn
      |> Map.put(:params, params)
      |> KanbanWeb.API.Me.DeviceController.call(action)
    end

    test "cannot revoke the person's other device", ctx do
      conn =
        in_flight(ctx, :delete, "/api/me/devices/#{ctx.other.id}", :delete, %{
          "id" => Integer.to_string(ctx.other.id)
        })

      assert json_response(conn, 401) == %{"error" => "Invalid access token"}
      assert is_nil(Repo.get!(Device, ctx.other.id).revoked_at)
      assert length(revoked_events(ctx.user.id)) == 1
    end

    test "gets 401 instead of a device list", ctx do
      conn = in_flight(ctx, :get, "/api/me/devices", :index, %{})
      assert json_response(conn, 401) == %{"error" => "Invalid access token"}
    end

    test "signing out answers 401 and records nothing more", ctx do
      conn = in_flight(ctx, :delete, "/api/me/devices/current", :delete_current, %{})
      assert json_response(conn, 401) == %{"error" => "Invalid access token"}
      assert length(revoked_events(ctx.user.id)) == 1
    end
  end

  describe "PUT /api/me/devices/current with a NUL byte (W2748)" do
    test "answers 422 on push_token and stores nothing", ctx do
      body = ctx.access_token |> update(%{"push_token" => "tok\u0000en"}) |> json_response(422)

      assert %{"errors" => %{"push_token" => [_ | _]}} = body
      assert is_nil(Repo.get!(Device, ctx.device.id).push_token)
    end
  end
end
