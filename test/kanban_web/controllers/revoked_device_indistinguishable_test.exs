defmodule KanbanWeb.RevokedDeviceIndistinguishableTest do
  @moduledoc """
  The revoke charter handed back by W2746 and W2748: a revoked device's
  tokens get exactly the answers an unknown token gets, status, body and
  headers alike, on `GET /api/me`, the refresh grant of `POST /oauth/token`
  and `POST /oauth/revoke`, and they record the same refusal reason, so no
  response tells a caller that a string was once a real token.
  """
  use KanbanWeb.ConnCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.DevicesFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.Devices

  @auth_failed [:kanban, :api, :auth_failed]

  setup do
    scope = user_scope_fixture()
    {revoked, revoked_tokens} = device_with_tokens_fixture(scope)
    {:ok, rotated} = Devices.rotate_refresh_token(revoked_tokens.refresh_token)
    {:ok, _revoked} = Devices.revoke_device(scope, revoked)

    %{
      unknown: %{access: "sdat_" <> random(), refresh: "sdrt_" <> random()},
      revoked: %{access: rotated.access_token, refresh: rotated.refresh_token},
      revoked_used: %{refresh: revoked_tokens.refresh_token}
    }
  end

  defp random, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  # What a caller can observe of a response: everything but the request id.
  defp observed(conn) do
    headers =
      conn.resp_headers
      |> Enum.reject(fn {name, _value} -> name in ["x-request-id"] end)
      |> Enum.sort()

    {conn.status, conn.resp_body, headers}
  end

  defp api_conn, do: put_req_header(build_conn(), "accept", "application/json")

  defp me(token) do
    api_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> get(~p"/api/me")
  end

  defp refresh(token) do
    post(api_conn(), ~p"/oauth/token", %{
      "grant_type" => "refresh_token",
      "client_id" => "stride-ios",
      "refresh_token" => token
    })
  end

  defp revoke(token),
    do: post(api_conn(), ~p"/oauth/revoke", %{"token" => token, "client_id" => "stride-ios"})

  test "GET /api/me answers a revoked device's token as an unknown one", ctx do
    attach_telemetry(@auth_failed)

    unknown = ctx.unknown.access |> me() |> observed()
    assert {401, _body, _headers} = unknown
    assert_received {:telemetry_event, @auth_failed, _, %{reason: unknown_reason}}

    assert ctx.revoked.access |> me() |> observed() == unknown
    assert_received {:telemetry_event, @auth_failed, _, %{reason: ^unknown_reason}}

    assert [first, second] =
             Kanban.AuditLog.list_events(action: :api_token_auth_failed)
             |> Enum.map(& &1.metadata["reason"])

    assert first == second
  end

  test "the refresh grant answers a revoked device's tokens, current or used, as unknown",
       ctx do
    unknown = ctx.unknown.refresh |> refresh() |> observed()
    assert {400, _body, _headers} = unknown

    assert ctx.revoked.refresh |> refresh() |> observed() == unknown
    assert ctx.revoked_used.refresh |> refresh() |> observed() == unknown
  end

  test "POST /oauth/revoke answers a revoked device's token as an unknown one", ctx do
    unknown = ctx.unknown.refresh |> revoke() |> observed()
    assert {200, "{}", _headers} = unknown

    assert ctx.revoked.refresh |> revoke() |> observed() == unknown
    assert ctx.revoked_used.refresh |> revoke() |> observed() == unknown
  end
end
