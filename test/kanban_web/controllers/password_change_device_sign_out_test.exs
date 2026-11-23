defmodule KanbanWeb.PasswordChangeDeviceSignOutTest do
  @moduledoc """
  D459: a password reset and the settings password change sign every mobile
  device of the user out, not only its web sessions. The old access token is
  refused by `GET /api/me`, the old refresh token by `POST /oauth/token`, and
  each device's socket is told to disconnect once the change commits.
  """

  use KanbanWeb.ConnCase, async: false

  import Kanban.DevicesFixtures

  alias Kanban.Accounts
  alias Kanban.Devices.Device
  alias Kanban.Devices.Revocation
  alias Kanban.Repo

  @new_password "a new valid password"

  setup :register_and_log_in_user

  setup %{user: user} do
    {device, issued} =
      user |> Kanban.AccountsFixtures.user_scope_fixture() |> device_with_tokens_fixture()

    Phoenix.PubSub.subscribe(Kanban.PubSub, Revocation.topic(device.id))
    %{device: device, issued: issued}
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

  defp assert_signed_out(device, issued) do
    assert json_response(me(issued.access_token), 401) == %{"error" => "Invalid access token"}
    assert %{"error" => "invalid_grant"} = json_response(refresh(issued.refresh_token), 400)
    assert Repo.get!(Device, device.id).revoked_at

    topic = Revocation.topic(device.id)
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
  end

  test "the device's tokens work before the password changes", %{issued: issued} do
    assert json_response(me(issued.access_token), 200)
  end

  test "After a password reset the old access token gets 401 on GET /api/me and the old refresh token gets invalid_grant on /oauth/token",
       %{user: user, device: device, issued: issued} do
    assert {:ok, {_user, _tokens}} =
             Accounts.reset_user_password(user, %{
               password: @new_password,
               password_confirmation: @new_password
             })

    assert_signed_out(device, issued)
  end

  test "After a password reset an open device socket receives the disconnect broadcast", %{
    user: user,
    device: device
  } do
    refute_received %Phoenix.Socket.Broadcast{}

    assert {:ok, {_user, _tokens}} =
             Accounts.reset_user_password(user, %{password: @new_password})

    topic = Revocation.topic(device.id)
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect", payload: %{}}
  end

  test "the settings password change signs the user's devices out", %{
    conn: conn,
    user: user,
    device: device,
    issued: issued
  } do
    conn =
      post(conn, ~p"/users/update-password", %{
        "user" => %{
          "email" => user.email,
          "password" => @new_password,
          "password_confirmation" => @new_password
        }
      })

    assert redirected_to(conn) == ~p"/users/settings"
    assert_signed_out(device, issued)
  end
end
