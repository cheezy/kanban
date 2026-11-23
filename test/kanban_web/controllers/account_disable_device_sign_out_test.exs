defmodule KanbanWeb.AccountDisableDeviceSignOutTest do
  @moduledoc """
  D465: a site admin disabling an account signs every mobile device of the
  user out for good, so enabling the account again does not bring the old
  device tokens back. The old access token is refused by `GET /api/me` and
  the old refresh token by `POST /oauth/token`.
  """

  use KanbanWeb.ConnCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.DevicesFixtures

  alias Kanban.Accounts

  setup do
    user = user_fixture()
    {_device, issued} = user |> user_scope_fixture() |> device_with_tokens_fixture()
    %{user: user, issued: issued, admin: admin_fixture()}
  end

  defp api_conn, do: build_conn() |> put_req_header("accept", "application/json")

  defp me(access_token) do
    api_conn()
    |> put_req_header("authorization", "Bearer " <> access_token)
    |> get(~p"/api/me")
  end

  defp refresh(refresh_token) do
    post(api_conn(), ~p"/oauth/token", %{
      "grant_type" => "refresh_token",
      "client_id" => "stride-ios",
      "refresh_token" => refresh_token
    })
  end

  test "the device's tokens work before the account is disabled", %{issued: issued} do
    assert json_response(me(issued.access_token), 200)
  end

  test "after a disable and an enable the old access token gets 401 on GET /api/me and the old refresh token gets invalid_grant",
       %{user: user, issued: issued, admin: admin} do
    assert {:ok, disabled} = Accounts.disable_user(user, admin)
    assert {:ok, _enabled} = Accounts.enable_user(disabled, admin)

    assert json_response(me(issued.access_token), 401) == %{"error" => "Invalid access token"}
    assert %{"error" => "invalid_grant"} = json_response(refresh(issued.refresh_token), 400)
  end
end
