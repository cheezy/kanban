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
  """

  alias Kanban.Accounts.User
  alias Kanban.Devices
  alias Kanban.Devices.Device
  alias Kanban.Repo

  @doc """
  Revokes every live device of `user` inside the caller's transaction and
  returns the revoked devices. Rolls the transaction back on failure.
  """
  @spec revoke!(User.t()) :: [Device.t()]
  def revoke!(%User{} = user) do
    case Devices.revoke_all_for_password_change(user) do
      {:ok, devices} -> devices
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

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
end
