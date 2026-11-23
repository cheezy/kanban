defmodule Kanban.Accounts.DeviceSignOut do
  @moduledoc """
  Signs a user's mobile devices out when their password is reset
  (`Kanban.Accounts.reset_user_password/2`) or changed
  (`Kanban.Accounts.update_user_password/2`), as both already sign out
  every web session.

  `revoke!/1` runs inside the password transaction: it revokes every live
  device of the user and expires their tokens, and rolls the transaction
  back if that fails, so the password never changes while an old device
  token stays valid. `announce/1` runs on the transaction's result once it
  has committed: it announces each revocation with reason
  `:password_changed`, which closes the device's socket, and drops the
  devices from the result so callers keep `{:ok, {user, expired_tokens}}`.
  A rolled-back change announces nothing.

  Disabling an account (`Kanban.Accounts.disable_user/2`) signs the devices
  out the same way: `revoke!/2` inside the disable's transaction, recording
  the admin in `revoked_by_id`, and `announce_disabled/2` once it commits,
  with reason `:account_disabled`. The devices stay revoked, so enabling the
  account again restores no device credential. An account disabled before
  that held on to its devices, so enabling it, by a site admin or by SCIM,
  revokes any it still holds with `revoke_stale!/2`.
  """

  alias Kanban.Accounts.User
  alias Kanban.Devices
  alias Kanban.Devices.Device
  alias Kanban.Repo

  @doc """
  Revokes every live device of `user` inside the caller's transaction,
  recording `revoked_by_id` (the user themself by default, or `nil` for no
  person), and returns the revoked devices. Rolls the transaction back on
  failure.
  """
  @spec revoke!(User.t()) :: [Device.t()]
  def revoke!(%User{id: user_id} = user), do: revoke!(user, user_id)

  @spec revoke!(User.t(), pos_integer() | nil) :: [Device.t()]
  def revoke!(%User{} = user, revoked_by_id) do
    case Devices.revoke_all_for_user(user, revoked_by_id) do
      {:ok, devices} -> devices
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  @doc """
  Revokes, inside an enable's transaction, every device the still-disabled
  `user` holds, recording `revoked_by_id`, and returns them. Only an account
  disabled before disabling revoked devices can hold one. An account that is
  not disabled returns `[]` and keeps its devices.
  """
  @spec revoke_stale!(User.t(), pos_integer() | nil) :: [Device.t()]
  def revoke_stale!(%User{disabled_at: nil}, _revoked_by_id), do: []
  def revoke_stale!(%User{} = user, revoked_by_id), do: revoke!(user, revoked_by_id)

  @doc """
  Announces the devices in a committed `{:ok, {user, expired_tokens,
  devices}}` and returns `{:ok, {user, expired_tokens}}`. An error passes
  through unchanged.
  """
  @spec announce({:ok, {User.t(), list(), [Device.t()]}} | {:error, term()}) ::
          {:ok, {User.t(), list()}} | {:error, term()}
  def announce({:ok, {%User{} = user, expired_tokens, devices}}) do
    :ok = Devices.announce_password_changed(user, devices)
    {:ok, {user, expired_tokens}}
  end

  def announce({:error, _reason} = error), do: error

  @doc """
  Announces the devices in a committed disable or enable, `{:ok, {user,
  devices}}`, with reason `:account_disabled` and `revoked_by_id` as whoever
  signed them out, and returns `{:ok, user}`. An error passes through
  unchanged.
  """
  @spec announce_disabled({:ok, {User.t(), [Device.t()]}} | {:error, term()}, pos_integer() | nil) ::
          {:ok, User.t()} | {:error, term()}
  def announce_disabled({:ok, {%User{} = user, devices}}, revoked_by_id) do
    :ok = Devices.announce_signed_out(user, devices, revoked_by_id, :account_disabled)
    {:ok, user}
  end

  def announce_disabled({:error, _reason} = error, _revoked_by_id), do: error
end
