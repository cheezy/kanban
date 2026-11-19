defmodule Kanban.Push.Adapter do
  @moduledoc """
  The seam in front of Apple and Google: one module per platform sends one
  push to one device (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.8).

  `Kanban.Push.APNs` and `Kanban.Push.FCM` implement it, and
  `Kanban.Push.adapter_for/1` picks one per platform from config, so tests
  swap in the `Kanban.Push.APNsMock` and `Kanban.Push.FCMMock` Mox doubles
  and never send a real push.

  ## Results

    * `:ok` — the push service accepted the push.
    * `:unregistered` — APNs `410 Unregistered` or FCM `UNREGISTERED`: the
      token is dead, and the caller clears the device's `push_token`.
    * `{:error, :not_configured}` — no credentials for this platform are
      configured, so nothing was sent.
    * `{:error, :no_push_token}` — the device has no push token.
    * `{:error, :rate_limited}` — APNs `429` or FCM `QUOTA_EXCEEDED`.
    * `{:error, reason}` — any other push-service answer, as the atom Pigeon
      gives it, such as `:expired_provider_token` or `:timeout`.

  A reason never carries the device token or a credential.
  """

  alias Kanban.Devices.Device
  alias Kanban.Push.Payload

  @type result :: :ok | :unregistered | {:error, atom()}

  @callback send(Device.t(), Payload.t()) :: result()

  @doc """
  The device's push token, or `{:error, :no_push_token}` when it has none
  (never registered, or cleared when the device was revoked).
  """
  @spec push_token(Device.t()) :: {:ok, String.t()} | {:error, :no_push_token}
  def push_token(%Device{push_token: token}) when is_binary(token) and token != "",
    do: {:ok, token}

  def push_token(%Device{}), do: {:error, :no_push_token}

  @doc """
  `{:ok, config}` when every one of `keys` is present in `config` as a
  non-blank string or a non-empty map; `:error` otherwise.
  """
  @spec credentials(keyword(), [atom()]) :: {:ok, keyword()} | :error
  def credentials(config, keys) when is_list(config) do
    if Enum.all?(keys, &present?(config[&1])), do: {:ok, config}, else: :error
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_map(value), do: map_size(value) > 0
  defp present?(_value), do: false
end
