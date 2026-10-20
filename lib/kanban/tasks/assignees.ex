defmodule Kanban.Tasks.Assignees do
  @moduledoc """
  Who a task may be newly assigned to (D385).

  A disabled account cannot sign in, so work assigned to it sits unowned. Its
  `board_users` row survives the disable, which is why a board-membership
  check alone still lets it through. Every write path that sets
  `assigned_to_id` therefore also refuses a disabled user:

    * `Kanban.Tasks.Lifecycle.update_task/3` (the task form and any other
      `Kanban.Tasks.update_task/2,3` caller, including the goal cascade)
      pipes its changeset through `validate_enabled_assignee/1`.
    * `KanbanWeb.TaskLive.Form.RelationalScopes` asks `disabled?/1` before
      the save reaches the context, so the form shows its usual targeted
      error.
    * `Kanban.Tasks.BulkActions` and `Kanban.Tasks.InterventionTransactions`
      count only enabled board members and org-admins as assignable
      (`Kanban.Boards.Assignable`), and the goal-reassign
      dialog (`KanbanWeb.AgentsLive.Interventions`) does not offer the others.
    * `Kanban.Tasks.Creation` and `Kanban.Tasks.GoalCreation` do not let a
      new child inherit a goal's assignee who is disabled; the child starts
      unassigned.

  The check reads `disabled_at` from the database, never from a `%User{}`
  struct a caller holds, so a struct loaded before the disable cannot slip
  through. Only a *change* of assignee is checked: a task whose existing
  assignee was disabled later can still be saved, and clearing the assignee
  (`nil`) always works. Existing assignments are never touched here.

  The refusal message is deliberately the same generic "no access" wording
  the board-membership check uses, so it reveals nothing about the account's
  state. It is listed in `priv/gettext/errors.pot` and every locale's
  `errors.po`; it must not drift without updating those entries.
  """

  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Repo

  @disabled_assignee_message "does not have access to this board"

  @doc """
  The error message attached to `:assigned_to_id` when the new assignee is a
  disabled account.

      iex> Kanban.Tasks.Assignees.disabled_assignee_message()
      "does not have access to this board"
  """
  def disabled_assignee_message, do: @disabled_assignee_message

  # The largest id a Postgres bigint holds; a larger one cannot name a user.
  @max_bigint 9_223_372_036_854_775_807

  @doc """
  Returns `true` when the user with `user_id` exists and is disabled, read
  from the database. A missing user, or an id outside the bigint range, returns
  `false` without failing: the `assigned_to_id` foreign key and the task
  changeset's own id validation refuse those writes on their own.
  """
  @spec disabled?(integer()) :: boolean()
  def disabled?(user_id) when is_integer(user_id) and abs(user_id) <= @max_bigint do
    from(u in User, where: u.id == ^user_id and not is_nil(u.disabled_at))
    |> Repo.exists?()
  end

  def disabled?(user_id) when is_integer(user_id), do: false

  @doc """
  Adds an `:assigned_to_id` error to `changeset` when it changes the assignee
  to a disabled user. An unchanged assignee, a cleared assignee (`nil`) and an
  assignee that already carries an error (such as an out-of-range id) are left
  as they are.
  """
  @spec validate_enabled_assignee(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_enabled_assignee(%Ecto.Changeset{} = changeset) do
    user_id = get_change(changeset, :assigned_to_id)

    if is_integer(user_id) and not Keyword.has_key?(changeset.errors, :assigned_to_id) and
         disabled?(user_id),
       do: add_error(changeset, :assigned_to_id, @disabled_assignee_message),
       else: changeset
  end
end
