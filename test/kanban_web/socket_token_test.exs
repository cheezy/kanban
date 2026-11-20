defmodule KanbanWeb.SocketTokenTest do
  use ExUnit.Case, async: true

  alias Kanban.Devices.Device
  alias KanbanWeb.SocketToken
  alias KanbanWeb.UnsubscribeToken

  @device %Device{id: 7, user_id: 3}

  defp now, do: System.system_time(:second)

  test "max_age/0 is 60 seconds" do
    assert SocketToken.max_age() == 60
  end

  test "sign/2 returns a token naming the device, and when it expires" do
    signed_at = now()
    {token, expires_at} = SocketToken.sign(@device, signed_at: signed_at)

    assert DateTime.to_unix(expires_at) == signed_at + 60
    assert {:ok, %{device_id: 7, user_id: 3, token_id: token_id}} = SocketToken.verify(token)
    assert byte_size(token_id) == 22
  end

  test "each token carries its own id" do
    {first, _} = SocketToken.sign(@device)
    {second, _} = SocketToken.sign(@device)

    {:ok, %{token_id: first_id}} = SocketToken.verify(first)
    {:ok, %{token_id: second_id}} = SocketToken.verify(second)
    refute first_id == second_id
  end

  test "verify/1 refuses an expired token" do
    {token, _} = SocketToken.sign(@device, signed_at: now() - 61)
    assert SocketToken.verify(token) == {:error, :expired}
  end

  test "verify/1 accepts a token just under its max age" do
    {token, _} = SocketToken.sign(@device, signed_at: now() - 59)
    assert {:ok, _claims} = SocketToken.verify(token)
  end

  test "verify/1 refuses tampered, foreign and non-string tokens" do
    {token, _} = SocketToken.sign(@device)

    assert SocketToken.verify(token <> "x") == {:error, :invalid}
    unsubscribe = UnsubscribeToken.sign(3, :task_completed)
    assert SocketToken.verify(unsubscribe) == {:error, :invalid}
    assert SocketToken.verify("") == {:error, :invalid}
    assert SocketToken.verify(nil) == {:error, :invalid}
    assert SocketToken.verify(123) == {:error, :invalid}
  end

  test "verify/1 refuses a payload of the wrong shape under its salt" do
    token = Phoenix.Token.sign(KanbanWeb.Endpoint, "device-socket-token-v1", %{"device_id" => 7})
    assert SocketToken.verify(token) == {:error, :invalid}
  end
end
