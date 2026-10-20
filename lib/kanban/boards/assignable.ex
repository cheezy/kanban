defmodule Kanban.Boards.Assignable do
  @moduledoc """
  Who a board's tasks may be newly assigned to: every enabled user with a
  `board_users` row on the board, and every enabled org-admin of the
  Organization whose workspace holds the board.

  An org-admin reaches every board of their Organization through derived
  access (`Kanban.Workspaces.Policy`) without a row, and can already claim its
  tasks over the API, so the assignee pickers offer them too and the write
  paths accept them: the board's bulk-action bar and the task form
  (`Kanban.Boards.list_assignable_board_members/1`, `list_derived_assignees/1`),
  `Kanban.Tasks.BulkActions` and `Kanban.Tasks.InterventionTransactions`
  (`member?/3`). Disabled accounts are never newly assignable (D385). Every
  answer is read from the database.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias Kanban.Workspaces.Workspace

  @doc """
  True when the user with `user_id` may be newly assigned a task on the board
  with `board_id`: their account is enabled, and they hold a `board_users` row
  on the board or are an org-admin of its Organization. Pass the `repo` a
  caller's transaction runs on.
  """
  @spec member?(Ecto.Repo.t(), integer(), integer()) :: boolean()
  def member?(repo \\ Repo, board_id, user_id)
      when is_integer(board_id) and is_integer(user_id) do
    from(u in User,
      where: u.id == ^user_id and is_nil(u.disabled_at),
      where: u.id in subquery(row_user_ids(board_id)) or u.id in subquery(org_admin_ids(board_id))
    )
    |> repo.exists?()
  end

  @doc """
  The enabled org-admins of the board's Organization who hold no
  `board_users` row on it, ordered by id. Empty for a board in a personal
  workspace.
  """
  @spec list_derived_assignees(integer()) :: [User.t()]
  def list_derived_assignees(board_id) when is_integer(board_id) do
    from(u in User,
      where: u.id in subquery(org_admin_ids(board_id)),
      where: u.id not in subquery(row_user_ids(board_id)),
      where: is_nil(u.disabled_at),
      order_by: u.id
    )
    |> Repo.all()
  end

  defp row_user_ids(board_id),
    do: from(bu in BoardUser, where: bu.board_id == ^board_id, select: bu.user_id)

  defp org_admin_ids(board_id) do
    from(m in OrganizationMember,
      join: w in Workspace,
      on: w.organization_id == m.organization_id,
      join: b in Board,
      on: b.workspace_id == w.id,
      where: b.id == ^board_id and m.role == ^:org_admin,
      select: m.user_id
    )
  end
end
