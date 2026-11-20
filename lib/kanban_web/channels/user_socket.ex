defmodule KanbanWeb.UserSocket do
  @moduledoc """
  The Stride app's live-updates socket, at `/api/socket`
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.7, W2765).

  ## Connecting

  The app first calls `POST /api/me/socket_token` with its device access
  token, then connects with the returned token as the `token` connect
  parameter. `connect/3` accepts it only when:

    * it is a socket token `KanbanWeb.SocketToken` signed, under 60 seconds
      old; a device access token, a refresh token or any other value is
      refused, so the access token is never sent here;
    * the device it names is still signed in, and still belongs to the user
      it names (`Kanban.Devices.fetch_signed_in_device/1`), so a token issued
      before the device was revoked, or its user disabled, cannot connect;
    * it was never used before: its id is recorded, hashed, through
      `Kanban.Devices.Nonces.use_socket_token/3`, so it connects once, and of
      two connects racing with one token exactly one wins.

  Every refusal is the same `:error`, whatever the cause, and the cause is
  never logged. Phoenix logs only that a connection was refused (at `:info`,
  `Phoenix.Logger`), with the `token` parameter filtered
  (`:filter_parameters`).

  On success the socket assigns `:current_scope`, the same scope
  `KanbanWeb.Plugs.AuthenticateDeviceToken` builds for `/api/me/*`, and
  `:current_device`. It never assigns `:current_user` or `:api_token`, so
  agent code never treats it as an agent, and it is not mounted with the
  browser session.

  ## Disconnecting on revoke

  `id/1` is the device's own topic, `"device:<id>"`
  (`Kanban.Devices.device_topic/1`), not a topic of its own: Phoenix
  subscribes a socket only to the topic its `id/1` returns, and revoking a
  device broadcasts `"disconnect"` there (`Kanban.Devices.Revocation`), so
  revoking the device closes every socket it opened.

  A revoke that commits after `connect/3` read the device but before the
  socket subscribed is not seen by the socket. A channel added here must
  therefore check the device again when it is joined
  (`Kanban.Devices.Activity.signed_in?/1`); the plan (`:mobile_app`) was
  checked when the token was issued, and a channel checks it on join too.

  The app's channels (`me:inbox`, `me:agents`) come in later tasks.
  """
  use Phoenix.Socket

  alias Kanban.Devices
  alias Kanban.Devices.Nonces
  alias KanbanWeb.Plugs.AuthenticateDeviceToken
  alias KanbanWeb.SocketToken

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) when is_binary(token) do
    with {:ok, %{device_id: device_id, user_id: user_id, token_id: token_id}} <-
           SocketToken.verify(token),
         {:ok, %{user_id: ^user_id} = device} <- Devices.fetch_signed_in_device(device_id),
         :ok <- Nonces.use_socket_token(device, token_id, DateTime.utc_now()) do
      {:ok, assign_device(socket, device)}
    else
      _refused -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  defp assign_device(socket, device) do
    assign(socket,
      current_scope: AuthenticateDeviceToken.scope_for(device.user),
      current_device: Devices.touch_last_seen(device)
    )
  end

  @impl true
  def id(socket), do: Devices.device_topic(socket.assigns.current_device.id)
end
