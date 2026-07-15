defmodule Kanban.Accounts.AdminManagement do
  @moduledoc """
  Admin-facing user management: listing, disabling/enabling, and deletion.

  Exposed through the `Kanban.Accounts` facade via `defdelegate` — call these
  as `Accounts.list_users/0`, `Accounts.disable_user/1`, and so on rather than
  reaching into this module directly.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Accounts.UserToken
  alias Kanban.Boards
  alias Kanban.Repo

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
      true -> do_disable(user)
    end
  end

  defp do_disable(user) do
    user
    |> User.disabled_changeset(DateTime.utc_now(:second))
    |> Repo.update()
  end

  @doc """
  Enables a user by clearing `disabled_at`.

  ## Examples

      iex> enable_user(user)
      {:ok, %User{}}

  """
  def enable_user(%User{} = user) do
    user
    |> User.disabled_changeset(nil)
    |> Repo.update()
  end

  @doc """
  Deletes a user along with their session and email tokens.

  `current_user` is the admin performing the deletion, passed last to match
  `Kanban.Boards.remove_user_from_board/3`.

  Deletes nothing and returns `{:error, reason}` when:

    * `:unauthorized` - the acting user is not an enabled admin
    * `:cannot_delete_self` - the target is the acting user
    * `:user_has_boards` - the target belongs to at least one board
    * `:last_admin` - the target is the last admin

  ## Examples

      iex> delete_user(user, admin)
      {:ok, %User{}}

      iex> delete_user(admin, admin)
      {:error, :cannot_delete_self}

  """
  def delete_user(%User{} = user, %User{} = current_user) do
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

  defp delete_user_and_tokens(user) do
    Repo.transact(fn ->
      Repo.delete_all(UserToken.by_user_and_contexts_query(user, :all))
      Repo.delete(user)
    end)
  end

  # Only enabled admins count as "remaining". A disabled admin cannot log in to
  # re-enable anyone, so treating one as a remaining admin would allow deleting
  # the last admin who can actually sign in and lock the system out permanently.
  #
  # The head matches any admin, enabled or not: a disabled admin still needs the
  # guard, since deleting the only admin row leaves nobody to promote.
  defp last_admin?(%User{type: :admin} = user) do
    User
    |> where([u], u.type == :admin and is_nil(u.disabled_at) and u.id != ^user.id)
    |> Repo.exists?()
    |> Kernel.not()
  end

  defp last_admin?(_user), do: false
end
