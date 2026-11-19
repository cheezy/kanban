defmodule Kanban.Push.FCM do
  @moduledoc """
  Sends Android pushes through the Firebase Cloud Messaging HTTP v1 API with
  a service account, via Pigeon (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md
  §7.8, §15.2).

  Credentials come only from runtime config, which config/runtime.exs sets
  from the `FCM_*` environment variables in production:

      config :kanban, Kanban.Push.FCM,
        project_id: "<Firebase project id>",
        service_account: %{...decoded service-account JSON...}

  With either missing, `send/2` returns `{:error, :not_configured}` without
  touching Pigeon, and `Kanban.Push.Supervisor` starts no FCM connection.
  """

  @behaviour Kanban.Push.Adapter

  alias Kanban.Devices.Device
  alias Kanban.Push.Adapter
  alias Kanban.Push.FCM.Dispatcher
  alias Kanban.Push.Payload
  alias Pigeon.FCM.Notification

  @typedoc "The configured credentials, or `{:error, :not_configured}`."
  @type config_result :: {:ok, keyword()} | {:error, :not_configured}

  @credential_keys [:project_id, :service_account]

  # Pigeon's response atom -> the Kanban.Push.Adapter result. Every other
  # atom passes through as {:error, atom}.
  @results %{
    success: :ok,
    unregistered: :unregistered,
    quota_exceeded: {:error, :rate_limited}
  }

  @impl Adapter
  def send(%Device{} = device, %Payload{} = payload) do
    with {:ok, _config} <- config(),
         {:ok, _token} <- Adapter.push_token(device) do
      device
      |> build_notification(payload)
      |> Dispatcher.push()
      |> map_response()
    end
  end

  @doc """
  The FCM credentials from runtime config, or `{:error, :not_configured}`
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

  @doc """
  The FCM v1 message for `payload`: the notification from its title and body
  (a data-only message when it has neither), the payload's data as strings
  with `"collapse_id"` added, and the collapse id as the Android `tag` and
  `collapse_key`.
  """
  @spec build_notification(Device.t(), Payload.t()) :: Notification.t()
  def build_notification(%Device{push_token: token}, %Payload{} = payload) do
    notification = notification(payload)

    {:token, token}
    |> Notification.new(notification, Payload.string_data(payload))
    |> Map.put(:android, android(payload.collapse_id, notification))
  end

  @doc "Maps the notification Pigeon answered with to an adapter result."
  @spec map_response(Notification.t() | term()) :: Adapter.result()
  def map_response(%Notification{response: response}) when is_atom(response) and response != nil,
    do: Map.get(@results, response, {:error, response})

  def map_response(_other), do: {:error, :unknown_error}

  defp notification(%Payload{title: title, body: body}) do
    fields =
      for {key, value} <- [{"title", title}, {"body", body}],
          is_binary(value) and value != "",
          into: %{} do
        {key, value}
      end

    if map_size(fields) == 0, do: nil, else: fields
  end

  defp android(collapse_id, nil), do: %{"collapse_key" => collapse_id}

  defp android(collapse_id, _notification),
    do: %{"collapse_key" => collapse_id, "notification" => %{"tag" => collapse_id}}
end
