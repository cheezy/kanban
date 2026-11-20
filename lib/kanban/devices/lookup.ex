defmodule Kanban.Devices.Lookup do
  @moduledoc """
  Reading devices (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.1,
  §7.10): the device an access token belongs to, for
  `KanbanWeb.Plugs.AuthenticateDeviceToken`, and a person's own devices, for
  `GET /api/me/devices` and the settings page. Behind
  `Kanban.Devices.fetch_by_access_token/2`,
  `Kanban.Devices.authenticate_access_token/2`, `Kanban.Devices.fetch_device/2`,
  `Kanban.Devices.list_devices/1` and `Kanban.Devices.list_devices_for/2`;
  and whether anyone has a device at all, for showing the device lists only
  when they can matter (`Kanban.Devices.show_devices?/1`,
  `Kanban.Devices.users_with_active_devices/2`); and whether a person has a
  device a push can reach, for showing the push settings only when they can
  matter (`Kanban.Devices.push_device?/1`, `Kanban.Devices.show_push?/1`).
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Devices.Device
  alias Kanban.Devices.DeviceToken
  alias Kanban.Devices.PushTokens
  alias Kanban.Organizations.OrganizationMember
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

  @doc "See `Kanban.Devices.fetch_signed_in_device/1`."
  @spec fetch_signed_in_device(term()) :: {:ok, Device.t()} | {:error, :invalid_token}
  def fetch_signed_in_device(id) when is_integer(id) do
    query =
      from d in Device,
        join: u in assoc(d, :user),
        where: d.id == ^id and is_nil(d.revoked_at) and is_nil(u.disabled_at),
        select: {d, u}

    case Repo.one(query) do
      {device, user} -> {:ok, %{device | user: user}}
      nil -> {:error, :invalid_token}
    end
  end

  def fetch_signed_in_device(_id), do: {:error, :invalid_token}

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

  @doc "Whether the scope user has at least one device that is not revoked."
  @spec has_active_device?(Scope.t()) :: boolean()
  def has_active_device?(%Scope{user: %User{id: user_id}}) do
    from(d in Device, where: d.user_id == ^user_id and is_nil(d.revoked_at))
    |> Repo.exists?()
  end

  @doc "See `Kanban.Devices.push_device?/1`."
  @spec push_device?(Scope.t()) :: boolean()
  def push_device?(%Scope{user: %User{id: user_id}}) do
    # The push workers' own rule, so the page and delivery always agree on
    # which devices a push can reach.
    [user_id]
    |> PushTokens.user_ids_with_device()
    |> MapSet.member?(user_id)
  end

  @doc "See `Kanban.Devices.users_with_active_devices/2`."
  @spec users_with_active_devices(Scope.t(), [pos_integer()]) :: MapSet.t(pos_integer())
  def users_with_active_devices(%Scope{}, []), do: MapSet.new()

  def users_with_active_devices(%Scope{user: %User{id: actor_id}}, user_ids)
      when is_list(user_ids) do
    # One query for every id. The second join keeps it to the members of the
    # actor's own Organization (a person belongs to at most one), so an id
    # from another Organization, or an actor with none, matches nothing.
    from(d in Device,
      join: m in OrganizationMember,
      on: m.user_id == d.user_id,
      join: a in OrganizationMember,
      on: a.organization_id == m.organization_id and a.user_id == ^actor_id,
      where: d.user_id in ^user_ids and is_nil(d.revoked_at),
      distinct: true,
      select: d.user_id
    )
    |> Repo.all()
    |> MapSet.new()
  end
end
