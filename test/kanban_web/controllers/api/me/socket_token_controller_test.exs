defmodule KanbanWeb.API.Me.SocketTokenControllerTest do
  @moduledoc """
  Tests for `POST /api/me/socket_token`
  (`KanbanWeb.API.Me.SocketTokenController`), W2765. The socket it issues
  tokens for is tested in `test/kanban_web/channels/user_socket_test.exs`.
  """
  # async: false - some tests switch the global :plans_enforced application env on.
  use KanbanWeb.ConnCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.DevicesFixtures
  import Kanban.PlansHelpers

  alias Kanban.ApiTokens
  alias Kanban.Devices
  alias KanbanWeb.SocketToken

  @plan_required %{
    "error" => "plan_required",
    "feature" => "mobile_app",
    "message" => "The Stride app is available to boards in an Organization."
  }

  setup do
    user = user_fixture()
    scope = user_scope_fixture(user)
    {device, issued} = device_with_tokens_fixture(scope, %{device_class: :phone})

    %{user: user, scope: scope, device: device, phone: issued.access_token}
  end

  defp authed(token), do: put_req_header(build_conn(), "authorization", "Bearer " <> token)

  defp issue(token), do: token |> authed() |> post(~p"/api/me/socket_token")

  test "returns a single-use token bound to the device, valid 60 seconds", ctx do
    conn = issue(ctx.phone)
    body = json_response(conn, 201)

    assert %{"token" => token, "expires_at" => expires_at, "expires_in" => 60} = body["data"]
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]

    assert {:ok, %{device_id: device_id, user_id: user_id}} = SocketToken.verify(token)
    assert device_id == ctx.device.id
    assert user_id == ctx.user.id
    assert {:ok, _at, 0} = DateTime.from_iso8601(expires_at)
  end

  test "issues a different token on every call", ctx do
    first = ctx.phone |> issue() |> json_response(201)
    second = ctx.phone |> issue() |> json_response(201)

    refute first["data"]["token"] == second["data"]["token"]
  end

  test "refuses an agent API token and no token", ctx do
    board = ai_optimized_board_fixture(ctx.user)

    {:ok, {_api_token, agent_token}} =
      ApiTokens.create_api_token(ctx.user, board, %{"name" => "Agent"})

    assert agent_token |> issue() |> json_response(401)
    assert build_conn() |> post(~p"/api/me/socket_token") |> json_response(401)
  end

  test "refuses a revoked device's access token", ctx do
    {:ok, _revoked} = Devices.revoke_device(ctx.scope, ctx.device)

    assert ctx.phone |> issue() |> json_response(401) == %{"error" => "Invalid access token"}
  end

  test "answers 403 plan_required for a free user while plans are enforced", ctx do
    enforce_plans()

    assert ctx.phone |> issue() |> json_response(403) == @plan_required
  end
end
