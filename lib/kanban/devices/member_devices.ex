defmodule Kanban.Devices.MemberDevices do
  @moduledoc """
  An org-admin listing and revoking the devices of a member of their
  Organization, from the Members section of the org console (`/org`)
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.1 "Who sees devices",
  §9.5). Behind `Kanban.Devices.list_devices_for_member/2`,
  `Kanban.Devices.revoke_member_device/3` and
  `Kanban.Devices.revoke_all_for_member/3`.

  Every call re-checks the actor, never the LiveView: the scope's user must be
  an enabled org-admin of their own Organization, read from the database (in
  a revoke, under the Organization's row lock, the lock every membership write
  in `Kanban.Organizations.MembershipWrites` takes). The Organization is always
  the actor's own; it never comes from the caller. A member is looked up only
  through their current membership of that Organization, so a user or device
  id from another Organization, or of someone who has left it, is
  `{:error, :not_found}`.

  Only an ordinary `:member`'s devices are reached here, as
  `Kanban.Organizations.MemberRemoval` reaches only members: an org-admin's
  devices are `{:error, :org_admin}`, and an org-admin manages their own
  devices on `/users/settings`.

  A revocation goes through `Kanban.Devices.Revocation` with the reason
  `:org_admin`, so it writes the same `:device_revoked` audit row, emits the
  same `[:kanban, :device, :revoked]` event and broadcasts the same
  disconnect as `Kanban.Devices.revoke_device/4` does for the device's owner.
  A device that is already revoked is left unchanged and announced again
  never; revoking one alone says so, as `{:error, :already_revoked}`.

  `watch/2` lists as `list/2` does and subscribes the caller to the member's
  device revocations, so the console reads an open list again when another
  page revokes one of the member's devices.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Devices.Device
  alias Kanban.Devices.Revocation
  alias Kanban.Organizations
  alias Kanban.Organizations.MembershipWrites
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo

  @max_bigint 9_223_372_036_854_775_807

  @typedoc "Why an org-admin's device request was refused."
  @type error :: :unauthorized | :not_found | :org_admin | :already_revoked

  @doc """
  Lists the devices, not revoked, of the member with `member_user_id`, newest
  first. See `Kanban.Devices.list_devices_for_member/2`.
  """
  @spec list(Scope.t(), term()) :: {:ok, [Device.t()]} | {:error, error()}
  def list(%Scope{user: %User{} = actor}, member_user_id) do
    with {:ok, user_id} <- parse_id(member_user_id),
         {:ok, organization_id} <- admin_organization(actor),
         {:ok, _membership} <- ordinary_member(organization_id, user_id) do
      {:ok, member_devices(user_id)}
    end
  end

  @doc """
  As `list/2`, and on success also subscribes the caller to the member's
  device revocations (`Kanban.Devices.Revocation.user_topic/1`). See
  `Kanban.Devices.watch_member_devices/2`.
  """
  @spec watch(Scope.t(), term()) :: {:ok, [Device.t()]} | {:error, error()}
  def watch(%Scope{} = scope, member_user_id) do
    with {:ok, user_id} <- parse_id(member_user_id),
         {:ok, devices} <- list(scope, user_id) do
      :ok = Revocation.subscribe_user(user_id)
      {:ok, devices}
    end
  end

  @doc """
  Revokes the device with `device_id`, when it belongs to a member of the
  actor's Organization. A device that was already revoked is
  `{:error, :already_revoked}`. See `Kanban.Devices.revoke_member_device/3`.
  """
  @spec revoke_one(Scope.t(), term(), DateTime.t()) :: {:ok, Device.t()} | {:error, error()}
  def revoke_one(%Scope{user: %User{} = actor}, device_id, %DateTime{} = now) do
    with {:ok, id} <- parse_id(device_id) do
      fn -> revoke_one_locked(actor, id, now) end
      |> Repo.transact()
      |> announce_one(actor)
    end
  end

  @doc """
  Revokes every device, not already revoked, of the member with
  `member_user_id`. See `Kanban.Devices.revoke_all_for_member/3`.
  """
  @spec revoke_all(Scope.t(), term(), DateTime.t()) :: {:ok, [Device.t()]} | {:error, error()}
  def revoke_all(%Scope{user: %User{} = actor}, member_user_id, %DateTime{} = now) do
    with {:ok, user_id} <- parse_id(member_user_id) do
      fn -> revoke_all_locked(actor, user_id, now) end
      |> Repo.transact()
      |> announce_all(actor)
    end
  end

  defp revoke_one_locked(actor, device_id, now) do
    with {:ok, organization_id} <- locked_admin_organization(actor),
         {:ok, {device, membership}} <- lock_member_device(organization_id, device_id),
         :ok <- check_ordinary_member(membership),
         {:ok, result} <- Revocation.revoke_locked(device, actor.id, now) do
      {:ok, {result, membership.user}}
    end
  end

  defp revoke_all_locked(actor, user_id, now) do
    with {:ok, organization_id} <- locked_admin_organization(actor),
         {:ok, membership} <- ordinary_member(organization_id, user_id),
         {:ok, results} <- revoke_each(lock_member_devices(user_id), actor.id, now) do
      {:ok, {results, membership.user}}
    end
  end

  # Stops at the first failure, which rolls the whole transaction back.
  defp revoke_each(devices, revoked_by_id, now) do
    devices
    |> Enum.reduce_while({:ok, []}, fn device, {:ok, results} ->
      case Revocation.revoke_locked(device, revoked_by_id, now) do
        {:ok, result} -> {:cont, {:ok, [result | results]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  # The actor's Organization, when they are an enabled org-admin of it. The
  # Organization comes from their own membership, never from the caller.
  defp admin_organization(actor) do
    with %OrganizationMember{organization_id: organization_id} <-
           Organizations.get_membership(actor),
         true <- Organizations.org_admin?(actor, organization_id) do
      {:ok, organization_id}
    else
      _not_an_org_admin -> {:error, :unauthorized}
    end
  end

  # As admin_organization/1, re-checked under the Organization's row lock, so
  # a demotion or removal committed before the revoke is always seen.
  defp locked_admin_organization(actor) do
    with {:ok, organization_id} <- admin_organization(actor),
         :ok <- MembershipWrites.lock_organization(organization_id),
         true <- Organizations.org_admin?(actor, organization_id) do
      {:ok, organization_id}
    else
      _not_an_org_admin -> {:error, :unauthorized}
    end
  end

  defp ordinary_member(organization_id, user_id) do
    from(m in OrganizationMember,
      where: m.organization_id == ^organization_id and m.user_id == ^user_id,
      preload: :user
    )
    |> Repo.one()
    |> case do
      %OrganizationMember{} = membership ->
        with :ok <- check_ordinary_member(membership), do: {:ok, membership}

      nil ->
        {:error, :not_found}
    end
  end

  defp check_ordinary_member(%OrganizationMember{role: :member}), do: :ok
  defp check_ordinary_member(%OrganizationMember{}), do: {:error, :org_admin}

  defp member_devices(user_id) do
    from(d in Device,
      where: d.user_id == ^user_id and is_nil(d.revoked_at),
      order_by: [desc: d.inserted_at, desc: d.id]
    )
    |> Repo.all()
  end

  # The device and its owner's membership of the Organization, both locked:
  # a member removed meanwhile has no membership row, so the device is not
  # found.
  defp lock_member_device(organization_id, device_id) do
    from(d in Device,
      join: m in OrganizationMember,
      on: m.user_id == d.user_id and m.organization_id == ^organization_id,
      where: d.id == ^device_id,
      select: {d, m},
      lock: "FOR UPDATE"
    )
    |> Repo.one()
    |> case do
      {%Device{} = device, %OrganizationMember{} = membership} ->
        {:ok, {device, Repo.preload(membership, :user)}}

      nil ->
        {:error, :not_found}
    end
  end

  # In id order, as every other device lock takes them.
  defp lock_member_devices(user_id) do
    from(d in Device,
      where: d.user_id == ^user_id and is_nil(d.revoked_at),
      order_by: d.id,
      lock: "FOR UPDATE"
    )
    |> Repo.all()
  end

  defp announce_one({:ok, {{:unchanged, _device}, _owner}}, _actor),
    do: {:error, :already_revoked}

  defp announce_one({:ok, {result, owner}}, actor),
    do: Revocation.announce({:ok, result}, details(owner, actor))

  defp announce_one({:error, _reason} = error, _actor), do: error

  defp announce_all({:ok, {results, owner}}, actor) do
    details = details(owner, actor)

    revoked =
      for {:revoked, _device} = result <- results do
        {:ok, device} = Revocation.announce({:ok, result}, details)
        device
      end

    {:ok, revoked}
  end

  defp announce_all({:error, _reason} = error, _actor), do: error

  defp details(%User{} = owner, %User{id: actor_id}),
    do: [owner: owner, user_id: actor_id, reason: :org_admin]

  defp parse_id(id) when is_integer(id) and id > 0 and id <= @max_bigint, do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> parse_id(int_id)
      _other -> {:error, :not_found}
    end
  end

  defp parse_id(_id), do: {:error, :not_found}
end
