defmodule Kanban.Push do
  @moduledoc """
  Sends one push to one device through the adapter configured for the
  device's platform (`Kanban.Push.Adapter`).

  The adapters are set per platform:

      config :kanban, Kanban.Push,
        adapters: [ios: Kanban.Push.APNs, android: Kanban.Push.FCM]

  config/test.exs points both at Mox doubles, so no test reaches Apple or
  Google. See docs/push-notifications.md.
  """

  alias Kanban.Devices.Device
  alias Kanban.Push.Adapter
  alias Kanban.Push.Payload

  @doc """
  Sends `payload` to `device`. Returns the adapter's result, or
  `{:error, :no_push_token}` when the device has no push token and
  `{:error, :unsupported_platform}` when no adapter is configured for its
  platform; neither calls an adapter.
  """
  @spec send(Device.t(), Payload.t()) :: Adapter.result()
  def send(%Device{} = device, %Payload{} = payload) do
    with {:ok, _token} <- Adapter.push_token(device),
         {:ok, adapter} <- adapter_for(device.platform) do
      adapter.send(device, payload)
    end
  end

  @doc """
  The adapter module configured for `platform`, or
  `{:error, :unsupported_platform}`.
  """
  @spec adapter_for(atom()) :: {:ok, module()} | {:error, :unsupported_platform}
  def adapter_for(platform) do
    :kanban
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:adapters, [])
    |> Keyword.fetch(platform)
    |> case do
      {:ok, adapter} when is_atom(adapter) and not is_nil(adapter) -> {:ok, adapter}
      _missing -> {:error, :unsupported_platform}
    end
  end
end
