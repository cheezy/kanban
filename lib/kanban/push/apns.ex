defmodule Kanban.Push.APNs do
  @moduledoc """
  Sends iOS pushes through Apple Push Notification service with token-based
  (`.p8`) auth, via Pigeon (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md
  §7.8, §15.2).

  Credentials come only from runtime config, which config/runtime.exs sets
  from the `APNS_*` environment variables in production:

      config :kanban, Kanban.Push.APNs,
        key: "<.p8 file contents>",
        key_identifier: "<key id>",
        team_id: "<team id>",
        topic: "<app bundle id>"

  With any of them missing, `send/2` returns `{:error, :not_configured}`
  without touching Pigeon, and `Kanban.Push.Supervisor` starts no APNs
  connection. A device's `push_environment` picks the APNs endpoint:
  `:sandbox` goes to `Kanban.Push.APNs.SandboxDispatcher`, `:production` to
  `Kanban.Push.APNs.ProductionDispatcher`.
  """

  @behaviour Kanban.Push.Adapter

  alias Kanban.Devices.Device
  alias Kanban.Push.Adapter
  alias Kanban.Push.APNs.ProductionDispatcher
  alias Kanban.Push.APNs.SandboxDispatcher
  alias Kanban.Push.Payload
  alias Pigeon.APNS.Notification

  @typedoc "The configured credentials, or `{:error, :not_configured}`."
  @type config_result :: {:ok, keyword()} | {:error, :not_configured}

  @credential_keys [:key, :key_identifier, :team_id, :topic]

  # Pigeon's response atom -> the Kanban.Push.Adapter result. Every other
  # atom passes through as {:error, atom}.
  @results %{
    success: :ok,
    unregistered: :unregistered,
    too_many_requests: {:error, :rate_limited}
  }

  @impl Adapter
  def send(%Device{} = device, %Payload{} = payload) do
    with {:ok, config} <- config(),
         {:ok, _token} <- Adapter.push_token(device),
         {:ok, dispatcher} <- dispatcher_for(device.push_environment) do
      device
      |> build_notification(payload, config[:topic])
      |> dispatcher.push()
      |> map_response()
    end
  end

  @doc """
  The APNs credentials from runtime config, or `{:error, :not_configured}`
  when any of `#{inspect(@credential_keys)}` is missing or blank.
  """
  @spec config() :: config_result()
  def config do
    :kanban
    |> Application.get_env(__MODULE__, [])
    |> Adapter.credentials(@credential_keys)
    |> case do
      {:ok, config} -> {:ok, config}
      :error -> {:error, :not_configured}
    end
  end

  @doc "The dispatcher for a device's `push_environment`."
  @spec dispatcher_for(atom()) :: {:ok, module()} | {:error, :no_push_environment}
  def dispatcher_for(:sandbox), do: {:ok, SandboxDispatcher}
  def dispatcher_for(:production), do: {:ok, ProductionDispatcher}
  def dispatcher_for(_other), do: {:error, :no_push_environment}

  @doc """
  The APNs notification for `payload`: the alert from its title and body (or
  a silent `content-available` push, with no badge, when it has neither), the
  badge (a whole number; 0 clears it), the
  `apns-collapse-id`, `mutable-content` so the Notification Service Extension
  can refresh the widget, and the payload's data as custom keys.
  """
  @spec build_notification(Device.t(), Payload.t(), String.t() | nil) :: Notification.t()
  def build_notification(%Device{push_token: token}, %Payload{} = payload, topic) do
    payload
    |> alert()
    |> Notification.new(token, topic)
    |> Map.put(:collapse_id, payload.collapse_id)
    |> put_visibility(Payload.visible?(payload))
    |> put_badge(payload)
    |> Notification.put_custom(custom_data(payload))
  end

  @doc "Maps the notification Pigeon answered with to an adapter result."
  @spec map_response(Notification.t() | term()) :: Adapter.result()
  def map_response(%Notification{response: response}) when is_atom(response) and response != nil,
    do: Map.get(@results, response, {:error, response})

  def map_response(_other), do: {:error, :unknown_error}

  defp alert(%Payload{title: title, body: body}) do
    for {key, value} <- [{"title", title}, {"body", body}],
        is_binary(value) and value != "",
        into: %{} do
      {key, value}
    end
  end

  # Custom keys sit beside "aps" in the APNs payload, so a data key named
  # "aps" would replace the alert, badge and flags: it is dropped.
  defp custom_data(payload), do: payload |> Payload.string_data() |> Map.delete("aps")

  defp put_visibility(notification, true), do: Notification.put_mutable_content(notification)

  defp put_visibility(notification, false) do
    notification
    |> Map.update!(:payload, &Map.update!(&1, "aps", fn aps -> Map.delete(aps, "alert") end))
    |> Notification.put_content_available()
    |> Map.merge(%{push_type: "background", priority: 5})
  end

  # A background push may carry only content-available, so a silent payload
  # never sets the badge. 0 is a real badge: it clears the app icon's count.
  defp put_badge(notification, %Payload{badge: badge} = payload)
       when is_integer(badge) and badge >= 0 do
    if Payload.visible?(payload),
      do: Notification.put_badge(notification, badge),
      else: notification
  end

  defp put_badge(notification, _payload), do: notification
end
