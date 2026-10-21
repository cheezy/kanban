defmodule Kanban.Accounts.SSOUsers do
  @moduledoc """
  Account writes for single sign-on (`Kanban.SSO.Provisioning`).

  `register_sso_user/1` creates a confirmed account with no password and keeps
  every side effect of `Kanban.Accounts.register_user/1`: the hidden personal
  workspace is created in the same transaction and the
  `[:kanban, :user, :registration]` event is emitted after commit.

  `secure_linked_unconfirmed_user/1` protects against a pre-registered
  account: before single sign-on links an account whose email was never
  confirmed, whoever registered it may know its password, so the account is
  confirmed (the identity provider has verified the address), its password is
  removed and all its tokens (sessions, reset and confirmation links) are
  deleted.

  Reached through `Kanban.Accounts`.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Accounts.UserToken
  alias Kanban.Repo
  alias Kanban.Telemetry.AfterCommit
  alias Kanban.Workspaces

  @doc """
  Registers a confirmed, passwordless user from `%{email: ..., name: ...}`.

  A name the identity provider sends that Stride would refuse (for example
  one containing `&`) is dropped rather than failing the sign-in.
  """
  @spec register_sso_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def register_sso_user(attrs) when is_map(attrs) do
    changeset = registration_changeset(attrs)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:user, changeset)
    |> Ecto.Multi.run(:personal_workspace, fn _repo, %{user: user} ->
      Workspaces.create_personal_workspace(user)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} ->
        AfterCommit.defer(fn ->
          Kanban.Telemetry.emit([:kanban, :user, :registration], %{count: 1}, %{user_id: user.id})
        end)

        {:ok, user}

      {:error, _step, changeset, _changes} ->
        {:error, changeset}
    end
  end

  defp registration_changeset(attrs) do
    changeset = User.sso_registration_changeset(%User{}, attrs)

    if Keyword.has_key?(changeset.errors, :name),
      do: User.sso_registration_changeset(%User{}, Map.delete(attrs, :name)),
      else: changeset
  end

  @doc """
  Confirms an unconfirmed account, removes its password and deletes all its
  tokens, in one transaction. An already confirmed account is returned as it
  is.
  """
  @spec secure_linked_unconfirmed_user(User.t()) :: {:ok, User.t()} | {:error, term()}
  def secure_linked_unconfirmed_user(%User{confirmed_at: nil} = user) do
    Repo.transact(fn ->
      with {:ok, user} <-
             user
             |> Ecto.Changeset.change(
               confirmed_at: DateTime.utc_now(:second),
               hashed_password: nil
             )
             |> Repo.update() do
        Repo.delete_all(from(t in UserToken, where: t.user_id == ^user.id))
        {:ok, user}
      end
    end)
  end

  def secure_linked_unconfirmed_user(%User{} = user), do: {:ok, user}
end
