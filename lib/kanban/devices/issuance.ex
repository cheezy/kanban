defmodule Kanban.Devices.Issuance do
  @moduledoc """
  Creating a device and issuing its first token pair
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.1, §8), behind
  `Kanban.Devices.create_device/3` and `Kanban.Devices.issue_tokens/2`, and
  for `Kanban.Devices.CodeExchange`.

  Issuing locks the device FOR SHARE, so it waits for a revocation in flight
  and is then refused, and starts a new token family: the family the
  code exchange names (`Kanban.Devices.AuthorizationCodes.family_id/1`), or
  a random one.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Devices.Device
  alias Kanban.Devices.TokenPairs
  alias Kanban.Notifications
  alias Kanban.Repo

  @doc """
  See `Kanban.Devices.create_device/3`. `opts` takes `:sso_organization_id`,
  the single sign-on mark the authorization code carried
  (`Kanban.Devices.SsoExemption`); it is set on the device, never cast from
  `attrs`, and defaults to `nil`.
  """
  @spec create_device(Scope.t(), map(), DateTime.t(), keyword()) ::
          {:ok, Device.t()} | {:error, Ecto.Changeset.t()}
  def create_device(%Scope{user: %User{id: user_id}}, attrs, now, opts \\ []) do
    signed_in_at = DateTime.truncate(now, :second)

    %Device{user_id: user_id, sso_organization_id: Keyword.get(opts, :sso_organization_id)}
    |> Device.create_changeset(attrs, signed_in_at)
    |> Repo.insert()
    |> Notifications.ensure_push_settings_for_device()
  end

  @doc """
  Issues a new access and refresh token for `device` at `now`, in a new,
  random token family. See `Kanban.Devices.issue_tokens/2`.
  """
  @spec issue_tokens(Device.t(), DateTime.t()) ::
          {:ok, Kanban.Devices.issued()} | {:error, :revoked | :expired}
  def issue_tokens(%Device{} = device, now), do: issue_tokens(device, now, Ecto.UUID.generate())

  @doc """
  As `issue_tokens/2`, in the token family `family_id`.
  """
  @spec issue_tokens(Device.t(), DateTime.t(), Ecto.UUID.t()) ::
          {:ok, Kanban.Devices.issued()} | {:error, :revoked | :expired}
  def issue_tokens(%Device{id: device_id}, now, family_id) do
    issued_at = DateTime.truncate(now, :second)

    Repo.transact(fn ->
      from(d in Device, where: d.id == ^device_id, lock: "FOR SHARE")
      |> Repo.one()
      |> issue_for_locked(family_id, issued_at)
    end)
  end

  defp issue_for_locked(%Device{revoked_at: nil} = device, family_id, now) do
    if device |> TokenPairs.refresh_expiry(now) |> DateTime.compare(now) == :gt,
      do: TokenPairs.insert(device, family_id, now),
      else: {:error, :expired}
  end

  defp issue_for_locked(_revoked_or_missing, _family_id, _now), do: {:error, :revoked}
end
