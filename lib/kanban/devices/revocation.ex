defmodule Kanban.Devices.Revocation do
  @moduledoc """
  Revoking a device (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.10,
  §9.5, §16), behind `Kanban.Devices.revoke_device/4`,
  `Kanban.Devices.revoke_by_refresh_token/3` and refresh-token reuse
  detection.

  Revoking sets the device's `revoked_at`, clears its push token and expires
  every token it still holds, in the caller's transaction. Once that commits,
  `announce/2` makes the revocation known, whoever revoked it:

    * it writes the `:device_revoked` audit row with a `reason`;
    * it emits `[:kanban, :device, :revoked]` with the device's platform and
      the reason, never the device's name, a token or an id;
    * it broadcasts `%Phoenix.Socket.Broadcast{event: "disconnect"}` on
      `topic/1`, `"device:<id>"`, so a socket the device opened can be closed;
    * it broadcasts `{:device_revoked, device_id}` on `user_topic/1`,
      `"user_devices:<user id>"`, the device owner's topic, so a page listing
      their devices (`/users/settings`, the org console's Members section)
      reads its list again at once. The message carries the id alone.

  A device that was already revoked is returned unchanged and announced
  again never: a repeated sign-out writes one audit row, not two.

  The reasons are `:sign_out` (the app signed itself out), `:user` (the
  person revoked it from another device or the web), `:org_admin` (an
  Organization admin revoked a member's device), `:reuse_detected` (an
  old refresh token was presented again), `:password_changed` (the
  person reset or changed their password, which signs every device out) and
  `:account_disabled` (a site admin disabled the account, or SCIM
  deprovisioning did, which signs every device out for good).
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.AuditLog
  alias Kanban.Devices
  alias Kanban.Devices.Device
  alias Kanban.Devices.DeviceToken
  alias Kanban.Repo

  @reasons [:sign_out, :user, :org_admin, :reuse_detected, :password_changed, :account_disabled]

  # The reasons a person can give for revoking one of their own devices.
  @own_reasons [:sign_out, :user]

  @typedoc "Why a device was revoked."
  @type reason ::
          :sign_out | :user | :org_admin | :reuse_detected | :password_changed | :account_disabled

  @typedoc "A revocation inside a transaction: whether it changed the device."
  @type locked_result :: {:ok, {:revoked | :unchanged, Device.t()}} | {:error, :not_found}

  @doc "The reasons a revocation can record."
  @spec reasons() :: [reason()]
  def reasons, do: @reasons

  @doc """
  The PubSub topic a device's revocation is broadcast on: `"device:<id>"`.
  """
  @spec topic(pos_integer()) :: String.t()
  def topic(device_id) when is_integer(device_id), do: "device:#{device_id}"

  @doc """
  The PubSub topic a user's device revocations are broadcast on, as
  `{:device_revoked, device_id}`: `"user_devices:<user id>"`.
  """
  @spec user_topic(pos_integer()) :: String.t()
  def user_topic(user_id) when is_integer(user_id), do: "user_devices:#{user_id}"

  @doc "Subscribes the calling process to `user_topic/1` for `user_id`."
  @spec subscribe_user(pos_integer()) :: :ok | {:error, term()}
  def subscribe_user(user_id) when is_integer(user_id),
    do: Phoenix.PubSub.subscribe(Kanban.PubSub, user_topic(user_id))

  @doc "Unsubscribes the calling process from `user_topic/1` for `user_id`."
  @spec unsubscribe_user(pos_integer()) :: :ok
  def unsubscribe_user(user_id) when is_integer(user_id),
    do: Phoenix.PubSub.unsubscribe(Kanban.PubSub, user_topic(user_id))

  @doc """
  Revokes one of the scope user's own devices at `now`, recording the scope
  user in `revoked_by_id`. See `Kanban.Devices.revoke_device/4`.

  With `:by_device`, the device the request came from, that device is
  locked with the target, in id order, and a revoked one is refused with
  `{:error, :revoked}`: a device revoked while its request was in flight
  cannot revoke anything, itself included.

  With `report_unchanged: true`, a device found already revoked under its
  lock is `{:error, :already_revoked}` instead of being returned unchanged,
  for a page that tells the person so.
  """
  @spec revoke_own(Scope.t(), Device.t(), DateTime.t(), keyword()) ::
          {:ok, Device.t()} | {:error, :not_found | :revoked | :already_revoked}
  def revoke_own(
        %Scope{user: %User{id: user_id} = owner},
        %Device{user_id: user_id} = device,
        now,
        opts
      ) do
    reason = own_reason!(Keyword.get(opts, :reason, :user))
    by_id = by_device_id(Keyword.get(opts, :by_device))

    Repo.transact(fn ->
      device.id
      |> lock_devices(by_id)
      |> revoke_checked(device.id, by_id, user_id, now)
    end)
    |> report_unchanged(Keyword.get(opts, :report_unchanged, false))
    |> announce(owner: owner, user_id: user_id, reason: reason, ip: Keyword.get(opts, :ip))
  end

  def revoke_own(%Scope{}, %Device{}, _now, _opts), do: {:error, :not_found}

  defp report_unchanged({:ok, {:unchanged, %Device{}}}, true), do: {:error, :already_revoked}
  defp report_unchanged(result, _report?), do: result

  @doc """
  Revokes a locked device row, by `revoked_by_id`, inside the caller's
  transaction. A device that is already revoked comes back `:unchanged`, and
  a missing one is `{:error, :not_found}`.
  """
  @spec revoke_locked(Device.t() | nil, pos_integer() | nil, DateTime.t()) :: locked_result()
  def revoke_locked(nil, _revoked_by_id, _now), do: {:error, :not_found}

  def revoke_locked(%Device{revoked_at: %DateTime{}} = device, _revoked_by_id, _now),
    do: {:ok, {:unchanged, device}}

  def revoke_locked(%Device{} = device, revoked_by_id, now) do
    with {:ok, revoked} <- revoke_and_expire(device, revoked_by_id, now),
         do: {:ok, {:revoked, revoked}}
  end

  @doc """
  Revokes every live device of `user` at `now`, by `revoked_by_id`, inside
  the caller's transaction, and expires their tokens. The devices are locked
  in id order, so a device revoked meanwhile is left as it is. Returns the
  devices it revoked, to pass to `announce_all/2` once the transaction
  commits, or the first error, on which the caller rolls back.
  """
  @spec revoke_all_locked(User.t(), pos_integer() | nil, DateTime.t()) ::
          {:ok, [Device.t()]} | {:error, Ecto.Changeset.t()}
  def revoke_all_locked(%User{id: user_id}, revoked_by_id, now) do
    from(d in Device,
      where: d.user_id == ^user_id and is_nil(d.revoked_at),
      order_by: d.id,
      lock: "FOR UPDATE"
    )
    |> Repo.all()
    |> Enum.reduce_while({:ok, []}, fn device, {:ok, revoked} ->
      case revoke_and_expire(device, revoked_by_id, now) do
        {:ok, device} -> {:cont, {:ok, [device | revoked]}}
        {:error, _changeset} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, revoked} -> {:ok, Enum.reverse(revoked)}
      error -> error
    end
  end

  @doc """
  Announces each committed revocation in `devices` with `details`, as
  `announce/2` does one. Call it once the transaction has committed.
  """
  @spec announce_all([Device.t()], keyword()) :: :ok
  def announce_all(devices, details) when is_list(devices) do
    Enum.each(devices, &announce_revoked(&1, details))
  end

  @doc """
  Revokes the device and expires every token it still has live, which
  covers each of its token families. The caller holds the device's row lock
  and owns the transaction.
  """
  @spec revoke_and_expire(Device.t(), pos_integer() | nil, DateTime.t()) ::
          {:ok, Device.t()} | {:error, Ecto.Changeset.t()}
  def revoke_and_expire(%Device{} = device, revoked_by_id, now) do
    changeset = Device.revoke_changeset(device, revoked_by_id, now)

    with {:ok, revoked} <- Repo.update(changeset) do
      from(t in DeviceToken, where: t.device_id == ^revoked.id and t.expires_at > ^now)
      |> Repo.update_all(set: [expires_at: now])

      {:ok, revoked}
    end
  end

  @doc """
  Announces a committed revocation: the audit row, the telemetry event and
  the broadcast. Call it on the result of the transaction, never inside it.

  `details` takes `:owner`, the device's user; `:user_id`, who revoked it, for
  the audit row; `:reason`, one of `reasons/0`; and `:ip`. An `:unchanged`
  device is returned without being announced, and an error passes through.
  """
  @spec announce(locked_result() | {:ok, Device.t()} | {:error, term()}, keyword()) ::
          {:ok, Device.t()} | {:error, term()}
  def announce({:ok, {:revoked, %Device{} = device}}, details),
    do: announce_revoked(device, details)

  def announce({:ok, {:unchanged, %Device{} = device}}, _details), do: {:ok, device}
  def announce({:ok, %Device{} = device}, details), do: announce_revoked(device, details)
  def announce({:error, _reason} = error, _details), do: error

  defp announce_revoked(device, details) do
    owner = Keyword.fetch!(details, :owner)
    reason = reason!(Keyword.fetch!(details, :reason))

    AuditLog.event(:device_revoked,
      user_id: Keyword.get(details, :user_id),
      organization_id: Devices.organization_id(owner),
      device_id: device.id,
      device_user_id: owner.id,
      reason: reason,
      ip: Keyword.get(details, :ip)
    )

    Kanban.Telemetry.emit(
      [:kanban, :device, :revoked],
      %{count: 1},
      %{platform: platform(device), reason: reason}
    )

    broadcast_disconnect(device.id)
    Phoenix.PubSub.broadcast(Kanban.PubSub, user_topic(owner.id), {:device_revoked, device.id})

    {:ok, device}
  end

  # The message Phoenix.Socket closes a socket on when its id/1 is the topic,
  # as KanbanWeb.UserAuth sends on sign-out.
  defp broadcast_disconnect(device_id) do
    topic = topic(device_id)

    Phoenix.PubSub.broadcast(Kanban.PubSub, topic, %Phoenix.Socket.Broadcast{
      topic: topic,
      event: "disconnect",
      payload: %{}
    })
  end

  defp by_device_id(nil), do: nil
  defp by_device_id(%Device{id: id}) when is_integer(id), do: id

  # The target and the requesting device, locked together in id order so
  # two devices revoking each other never deadlock.
  defp lock_devices(device_id, by_id) do
    ids = [device_id, by_id] |> Enum.reject(&is_nil/1) |> Enum.uniq()

    from(d in Device,
      where: d.id in ^ids,
      order_by: d.id,
      lock: "FOR UPDATE"
    )
    |> Repo.all()
  end

  defp revoke_checked(rows, device_id, by_id, revoked_by_id, now) do
    if requester_revoked?(rows, by_id) do
      {:error, :revoked}
    else
      rows
      |> Enum.find(&(&1.id == device_id))
      |> revoke_locked(revoked_by_id, now)
    end
  end

  # A requesting device that is gone or revoked may not revoke anything.
  defp requester_revoked?(_rows, nil), do: false

  defp requester_revoked?(rows, by_id) do
    case Enum.find(rows, &(&1.id == by_id)) do
      %Device{revoked_at: nil} -> false
      _revoked_or_gone -> true
    end
  end

  defp platform(%Device{platform: platform}) when is_atom(platform) and not is_nil(platform),
    do: Atom.to_string(platform)

  defp platform(_device), do: nil

  defp own_reason!(reason) when reason in @own_reasons, do: reason

  defp own_reason!(reason),
    do:
      raise(
        ArgumentError,
        "a person revokes their own device with :user or :sign_out, got #{inspect(reason)}"
      )

  defp reason!(reason) when reason in @reasons, do: reason
  defp reason!(reason), do: raise(ArgumentError, "unknown revoke reason #{inspect(reason)}")
end
