defmodule Kanban.Accounts.AdminManagement do
  @moduledoc """
  Admin-facing user management: listing, disabling/enabling, and deletion.

  Exposed through the `Kanban.Accounts` facade via `defdelegate` — call these
  as `Accounts.list_users/0`, `Accounts.disable_user/1`, and so on rather than
  reaching into this module directly.

  A disable, enable or delete that changes something emits
  `[:kanban, :user, :disabled]`, `:enabled` or `:deleted` through
  `Kanban.Accounts.UserTelemetry`, with the administrator as `actor_user_id`.
  Every deletion attempt, successful or refused, is also recorded in
  `Kanban.AuditLog` as `:user_deleted` or `:user_delete_refused`.

  Disabling or deleting the last enabled org-admin of an Organization that has
  other members is refused with `:last_org_admin`, so no Organization is left
  without someone who can run it. The check
  (`Kanban.Organizations.ensure_not_last_working_org_admin/1`) runs in the
  same transaction as the write, under the Organization's row lock.

  Disabling a user does not close their open pages by itself: the caller
  disconnects them with `KanbanWeb.UserAuth.disconnect_live_sessions/1` and
  `Kanban.Accounts.list_session_tokens/1`.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Accounts.UserTelemetry
  alias Kanban.Accounts.UserToken
  alias Kanban.Boards
  alias Kanban.Organizations
  alias Kanban.Repo
  alias Kanban.Workspaces

  @doc """
  Returns every user, ordered by email.

  Disabled users are included — the admin list needs to show them in order to
  enable them again.

  ## Examples

      iex> list_users()
      [%User{}, ...]

  """
  def list_users do
    User
    |> order_by([u], asc: u.email)
    |> Repo.all()
  end

  @doc """
  Disables a user by setting `disabled_at` to the current UTC time.

  `current_user` is the admin performing the action, passed last to match
  `delete_user/2` and `Kanban.Boards.remove_user_from_board/3`.

  Disabling an already-disabled user is allowed and refreshes the timestamp.

  Changes nothing and returns `{:error, reason}` when:

    * `:unauthorized` - the acting user is not an enabled admin
    * `:cannot_disable_self` - the target is the acting user, which is the way
      a lone admin would lock everyone out
    * `:last_admin` - the target is the last admin
    * `:last_org_admin` - the target is the last enabled org-admin of an
      Organization that has other members

  ## Examples

      iex> disable_user(user, admin)
      {:ok, %User{}}

      iex> disable_user(admin, admin)
      {:error, :cannot_disable_self}

  """
  def disable_user(%User{} = user, %User{} = current_user) do
    cond do
      not authorized_admin?(current_user) -> {:error, :unauthorized}
      user.id == current_user.id -> {:error, :cannot_disable_self}
      last_admin?(user) -> {:error, :last_admin}
      true -> user |> do_disable() |> UserTelemetry.disabled(user, current_user)
    end
  end

  defp do_disable(user) do
    Repo.transact(fn ->
      with :ok <- Organizations.ensure_not_last_working_org_admin(user) do
        user
        |> User.disabled_changeset(DateTime.utc_now(:second))
        |> Repo.update()
      end
    end)
  end

  @doc """
  Enables a user by clearing `disabled_at`.

  `current_user` is the admin performing the action, passed last to match
  `disable_user/2` and `delete_user/2`. Re-enabling an account is a privilege
  grant (it undoes an admin lockout), so it is gated on the same enabled-admin
  check as its siblings. Unlike disable/delete there is no self-target or
  last-admin guard — enabling is not destructive.

  Returns `{:error, :unauthorized}` when the acting user is not an enabled admin.

  ## Examples

      iex> enable_user(user, admin)
      {:ok, %User{}}

      iex> enable_user(user, non_admin)
      {:error, :unauthorized}

  """
  def enable_user(%User{} = user, %User{} = current_user) do
    if authorized_admin?(current_user) do
      user |> do_enable() |> UserTelemetry.enabled(user, current_user)
    else
      {:error, :unauthorized}
    end
  end

  defp do_enable(user) do
    user
    |> User.disabled_changeset(nil)
    |> Repo.update()
  end

  @doc """
  Deletes a user along with their session and email tokens and their personal
  workspace, all in one transaction.

  `current_user` is the admin performing the deletion, passed last to match
  `Kanban.Boards.remove_user_from_board/3`.

  Deletes nothing and returns `{:error, reason}` when:

    * `:unauthorized` - the acting user is not an enabled admin
    * `:cannot_delete_self` - the target is the acting user
    * `:user_has_boards` - the target belongs to at least one board
    * `:last_admin` - the target is the last admin
    * `:last_org_admin` - the target is the last enabled org-admin of an
      Organization that has other members
    * `:personal_workspace_has_boards` - a board still sits in the target's
      personal workspace, even one they are not a member of. The foreign key
      refuses it inside the transaction, so a board placed there at the same
      moment is refused too and the whole delete rolls back

  A successful deletion records a `:user_deleted` audit event and every
  refusal above records a `:user_delete_refused` audit event naming its
  reason, both with `current_user` as the actor. They are written after the
  deletion's transaction has returned, so call this outside any enclosing
  transaction: rolling that one back would erase the record of the attempt.

  ## Examples

      iex> delete_user(user, admin)
      {:ok, %User{}}

      iex> delete_user(admin, admin)
      {:error, :cannot_delete_self}

  """
  def delete_user(%User{} = user, %User{} = current_user) do
    user
    |> attempt_delete(current_user)
    |> UserTelemetry.deleted(user, current_user)
  end

  defp attempt_delete(user, current_user) do
    cond do
      not authorized_admin?(current_user) -> {:error, :unauthorized}
      user.id == current_user.id -> {:error, :cannot_delete_self}
      Boards.user_has_boards?(user) -> {:error, :user_has_boards}
      last_admin?(user) -> {:error, :last_admin}
      true -> delete_user_and_tokens(user)
    end
  end

  # Rejects a disabled admin whose scope was re-fetched after the disable landed,
  # which covers any new request or mount. This reads the struct in memory, so an
  # actor loaded before the disable still passes — `last_admin?/1` is the
  # DB-authoritative check for that case. Closing the window entirely means
  # rejecting disabled users' sessions at the auth layer.
  defp authorized_admin?(%User{disabled_at: nil} = user), do: Accounts.admin?(user)
  defp authorized_admin?(%User{}), do: false

  # The personal workspace goes before the user row: its owner row is deleted
  # with the user, after which the workspace could no longer be found.
  defp delete_user_and_tokens(user) do
    Repo.transact(fn ->
      with :ok <- Organizations.ensure_not_last_working_org_admin(user),
           {_count, _} <- Repo.delete_all(UserToken.by_user_and_contexts_query(user, :all)),
           {:ok, _workspace} <- Workspaces.delete_personal_workspace(user) do
        Repo.delete(user)
      end
    end)
  end

  @doc """
  Returns true when `user` is a site admin and no other enabled site admin
  exists, read from the database. Disabling or deleting such a user would
  leave nobody who can sign in and administer the system.

  Only enabled admins count as "remaining": a disabled admin cannot log in to
  re-enable anyone. Any admin `user`, enabled or not, is checked, since
  deleting the only admin row leaves nobody to promote. A non-admin is never
  the last admin.

  Takes no lock; a caller that acts on the answer inside a transaction locks
  the admin rows first (see `Kanban.Accounts.AccountDeletion`).
  """
  @spec last_admin?(User.t()) :: boolean()
  def last_admin?(%User{type: :admin} = user) do
    User
    |> where([u], u.type == :admin and is_nil(u.disabled_at) and u.id != ^user.id)
    |> Repo.exists?()
    |> Kernel.not()
  end

  def last_admin?(_user), do: false
end
