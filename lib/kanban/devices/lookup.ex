defmodule Kanban.Devices.Lookup do
  @moduledoc """
  Reading devices (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.1,
  §7.10): the device an access token belongs to, for
  `KanbanWeb.Plugs.AuthenticateDeviceToken`, and a person's own devices, for
  `GET /api/me/devices` and the settings page. Behind
  `Kanban.Devices.fetch_by_access_token/2`,
  `Kanban.Devices.authenticate_access_token/2`, `Kanban.Devices.fetch_device/2`,
  `Kanban.Devices.list_devices/1` and `Kanban.Devices.list_devices_for/2`.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Devices.Device
  alias Kanban.Devices.DeviceToken
  alias Kanban.Repo

  @doc "See `Kanban.Devices.fetch_by_access_token/2`."
  @spec fetch_by_access_token(term(), DateTime.t()) ::
          {:ok, Device.t()} | {:error, :invalid_token}
  def fetch_by_access_token(token, now) do
    case authenticate_access_token(token, now) do
      {:ok, device} -> {:ok, device}
      {:error, _expired_or_invalid} -> {:error, :invalid_token}
    end
  end

  @doc "See `Kanban.Devices.authenticate_access_token/2`."
  @spec authenticate_access_token(term(), DateTime.t()) ::
          {:ok, Device.t()} | {:error, :expired_token | :invalid_token}
  def authenticate_access_token(token, now) when is_binary(token) do
    hash = DeviceToken.hash_token(token)
    at = DateTime.truncate(now, :second)

    # One read whatever the outcome, so a recognised token and an unknown
    # one cost the same.
    query =
      from t in DeviceToken,
        join: d in assoc(t, :device),
        join: u in assoc(d, :user),
        where: t.token_hash == ^hash and t.kind == :access,
        select: {t.expires_at, d, u}

    query
    |> Repo.one()
    |> access_token_result(at)
  end

  def authenticate_access_token(_token, _now), do: {:error, :invalid_token}

  defp access_token_result(nil, _now), do: {:error, :invalid_token}

  defp access_token_result({_expires_at, %Device{revoked_at: %DateTime{}}, _user}, _now),
    do: {:error, :invalid_token}

  defp access_token_result({_expires_at, _device, %User{disabled_at: %DateTime{}}}, _now),
    do: {:error, :invalid_token}

  defp access_token_result({expires_at, device, user}, now) do
    if DateTime.compare(expires_at, now) == :gt,
      do: {:ok, %{device | user: user}},
      else: {:error, :expired_token}
  end

  @doc "See `Kanban.Devices.fetch_device/2`."
  @spec fetch_device(Scope.t(), pos_integer()) :: {:ok, Device.t()} | {:error, :not_found}
  def fetch_device(%Scope{user: %User{id: user_id}}, id) when is_integer(id) do
    case Repo.get_by(Device, id: id, user_id: user_id) do
      %Device{} = device -> {:ok, device}
      nil -> {:error, :not_found}
    end
  end

  @doc "See `Kanban.Devices.list_devices_for/2`."
  @spec list_devices_for(Scope.t(), Device.t()) :: {:ok, [Device.t()]} | {:error, :revoked}
  def list_devices_for(%Scope{} = scope, %Device{id: id}) do
    devices = list_devices(scope)
    if Enum.any?(devices, &(&1.id == id)), do: {:ok, devices}, else: {:error, :revoked}
  end

  @doc "See `Kanban.Devices.list_devices/1`."
  @spec list_devices(Scope.t()) :: [Device.t()]
  def list_devices(%Scope{user: %User{id: user_id}}) do
    from(d in Device,
      where: d.user_id == ^user_id and is_nil(d.revoked_at),
      order_by: [desc: d.inserted_at, desc: d.id]
    )
    |> Repo.all()
  end
end
