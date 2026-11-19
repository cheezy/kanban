defmodule KanbanWeb.API.Me.DeviceJSON do
  @moduledoc """
  JSON rendering for the device routes under `/api/me/devices` (W2748).

  A device renders the keys `KanbanWeb.API.Me.MeJSON.device/1` renders, plus
  whether it is the device making the request, its locale, time zone and push
  environment, and whether it has a push token. The push token itself, the
  approval public key and the token hashes are never rendered.
  `priv/openapi/stride-api.json` documents the same keys as `UserDevice`, and
  `test/kanban_web/controllers/api/open_api_contract_test.exs` checks they
  agree. Add keys, never remove or rename one a supported app version reads.
  """

  alias Kanban.Devices.Device
  alias KanbanWeb.API.Me.MeJSON

  @doc "The person's devices."
  def index(%{devices: devices, current_id: current_id}) do
    %{data: Enum.map(devices, &device(&1, current_id))}
  end

  @doc "One device."
  def show(%{device: device, current_id: current_id}) do
    %{data: device(device, current_id)}
  end

  @doc """
  One device, with `current` true when it is the device whose token made the
  request.
  """
  def device(%Device{} = device, current_id) do
    device
    |> MeJSON.device()
    |> Map.merge(%{
      current: device.id == current_id,
      locale: device.locale,
      time_zone: device.time_zone,
      push_environment: device.push_environment,
      push_registered: is_binary(device.push_token)
    })
  end
end
