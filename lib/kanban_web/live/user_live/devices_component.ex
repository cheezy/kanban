defmodule KanbanWeb.UserLive.DevicesComponent do
  @moduledoc """
  The Devices section of `/users/settings`: the phones and tablets the signed-in
  person is signed in to Stride on, with a Revoke button for each
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.1 "Who sees devices").

  Revoking goes through `Kanban.Devices.revoke_device/4` with the reason
  `:user`, which writes the `:device_revoked` audit row, expires the device's
  tokens and broadcasts its disconnect: the device's next API call answers
  401. The list is read again on every update and after each revoke. The
  settings page subscribes to the person's device revocations and updates
  this component on each one (it passes a new `rev`), so a device revoked elsewhere (by an
  org-admin, on another page or by the device itself) leaves the list at
  once; a Revoke on a row that is already revoked says so and changes
  nothing. A device id from the event is only a hint:
  `Kanban.Devices.fetch_device/2` finds only the person's own devices.

  The outcome of a revoke is shown in the section itself (`#devices-notice`),
  not as a page flash: a component's flash reaches the page only when it
  navigates.
  """
  use KanbanWeb, :live_component

  import KanbanWeb.Components.DeviceList, only: [device_list: 1]

  alias Kanban.Devices

  @max_bigint 9_223_372_036_854_775_807

  @impl true
  def update(%{current_scope: scope} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:notice, fn -> nil end)
     |> assign(:devices, Devices.list_devices(scope))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <p
        :if={@notice}
        id="devices-notice"
        role={if elem(@notice, 0) == :error, do: "alert", else: "status"}
        style="margin: 8px 0 4px; font-size: 12.5px; font-weight: 500; color: var(--ink);"
      >
        {elem(@notice, 1)}
      </p>
      <.device_list
        id="device-list"
        id_prefix="device"
        devices={@devices}
        revoke_event="revoke_device"
        revoke_confirm={
          gettext("Revoke this device? It is signed out of Stride and must sign in again.")
        }
        empty_text={gettext("No phones or tablets are signed in to your account.")}
        target={@myself}
      />
    </div>
    """
  end

  @impl true
  def handle_event("revoke_device", %{"device_id" => device_id}, socket)
      when is_binary(device_id) or is_integer(device_id) do
    scope = socket.assigns.current_scope

    result =
      with {:ok, id} <- parse_id(device_id),
           {:ok, device} <- Devices.fetch_device(scope, id) do
        Devices.revoke_device(scope, device, DateTime.utc_now(),
          reason: :user,
          report_unchanged: true
        )
      end

    {:noreply, respond(result, socket)}
  end

  # A crafted event with no id, or an id that is not a string or an integer,
  # changes nothing.
  def handle_event("revoke_device", _params, socket), do: {:noreply, socket}

  defp respond({:ok, _device}, socket) do
    socket
    |> assign(:notice, {:info, gettext("Device revoked.")})
    |> refresh()
  end

  defp respond({:error, :already_revoked}, socket) do
    socket
    |> assign(:notice, {:info, gettext("That device was already signed out.")})
    |> refresh()
  end

  defp respond({:error, _not_found}, socket) do
    socket
    |> assign(:notice, {:error, gettext("Device not found.")})
    |> refresh()
  end

  defp refresh(socket),
    do: assign(socket, :devices, Devices.list_devices(socket.assigns.current_scope))

  defp parse_id(id) when is_integer(id) and id > 0 and id <= @max_bigint, do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> parse_id(int_id)
      _other -> {:error, :not_found}
    end
  end

  defp parse_id(_id), do: {:error, :not_found}
end
