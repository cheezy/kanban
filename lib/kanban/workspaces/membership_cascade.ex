defmodule Kanban.Workspaces.MembershipCascade do
  @moduledoc """
  What ending someone's place in a workspace does to their boards there.

  Used by `Kanban.Workspaces.remove_member/3` (one workspace) and by
  `Kanban.Organizations.MemberRemoval` (every workspace of an Organization).
  `remove/2` runs inside the caller's transaction and, for every board in the
  given workspaces:

    * deletes the user's `board_users` row,
    * revokes the user's API tokens for the board, and their workspace tokens
      for the workspace (W2220), so an agent acting through one loses access at
      once, and
    * unassigns the user from the board's open (unarchived) tasks, as
      `Kanban.Boards.MembershipChanges.remove_user_from_board/3` does.

  The user's **owner** row is deleted too. `remove_user_from_board/3` refuses
  that, because a board without an owner in a personal workspace would be seen
  by nobody. These boards are in org workspaces, which the Organization's
  org-admins always reach through derived access
  (`Kanban.Workspaces.Policy`), so the board is never stranded, and keeping
  the row would leave a removed member with owner access. A board left without
  an owner row is managed by the org-admins.

  `notify/3` reports each removed row once the transaction has committed, in
  the same way `remove_user_from_board/3` does.

  `revoke_derived_tokens/2` is the narrower cascade for losing org-admin
  access alone (`Kanban.Organizations.remove_org_admin/3`): it revokes only the
  tokens on boards whose write access came through that access, plus every
  workspace token the user holds in the Organization, which only an org-admin
  may hold (W2220), and
  `notify_derived_access_ended/2` tells those boards' open pages after commit.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.ApiTokens
  alias Kanban.ApiTokens.ApiToken
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Boards.MembershipChanges
  alias Kanban.Repo
  alias Kanban.Tasks.Task

  @type removed :: [{Board.t(), BoardUser.t(), non_neg_integer()}]

  @doc """
  Deletes `user_id`'s board memberships, revokes their API tokens and
  unassigns their open tasks on every board in `workspace_ids`. Call it inside
  a transaction.

  Returns `{board, board_user, revoked_count}` for each membership deleted, to
  pass to `notify/3` after commit. Tokens on boards where the user had no row
  are revoked as well, with nothing to report.
  """
  @spec remove(integer(), [integer()]) :: removed()
  def remove(_user_id, []), do: []

  def remove(user_id, workspace_ids) when is_integer(user_id) and is_list(workspace_ids) do
    removed = user_id |> lock_rows(workspace_ids) |> delete_rows(user_id)
    revoke_remaining_tokens(user_id, workspace_ids)
    unassign_open_tasks(user_id, workspace_ids)
    removed
  end

  @doc """
  Reports each membership `remove/2` deleted, through
  `Kanban.Boards.MembershipChanges.notify_removed/5`. Call it only after the
  transaction has committed. Returns `:ok`.
  """
  @spec notify(removed(), User.t(), User.t()) :: :ok
  def notify(removed, %User{} = user, %User{} = actor) do
    Enum.each(removed, fn {board, board_user, revoked} ->
      MembershipChanges.notify_removed(board, user, board_user, revoked, actor)
    end)
  end

  @doc """
  Revokes `user_id`'s API tokens on the boards of `organization_id`'s
  workspaces that they hold no `:owner` or `:modify` `board_users` row on: the
  boards whose write access came only through derived org-admin access
  (`Kanban.Workspaces.Policy`). A `:read_only` row cannot mint a token, so a
  token on such a board was minted through derived access and goes too. Call
  it inside the transaction that ends that access, so an agent acting through
  such a token loses access with it. Tokens on boards they can still modify
  are kept. Their workspace tokens in the Organization's workspaces are revoked
  as well (W2220). Returns the number revoked.
  """
  @spec revoke_derived_tokens(integer(), integer()) :: non_neg_integer()
  def revoke_derived_tokens(user_id, organization_id)
      when is_integer(user_id) and is_integer(organization_id) do
    {revoked, _} =
      from(t in ApiToken,
        where:
          t.user_id == ^user_id and is_nil(t.revoked_at) and
            t.board_id in subquery(derived_board_ids_query(user_id, organization_id))
      )
      |> Repo.update_all(set: [revoked_at: DateTime.utc_now(:second)])

    revoked + ApiTokens.revoke_user_workspace_tokens(user_id, organization_id)
  end

  @doc """
  Broadcasts `{Kanban.Boards, :members_changed, board_id}` on `"board:<id>"`
  for every board of `organization_id`'s workspaces that `user_id` holds no
  `:owner` or `:modify` `board_users` row on — the boards whose derived access
  just ended or narrowed to a `:read_only` row — so an open board page re-reads
  the viewer's access and sends them away or drops their write controls
  (`KanbanWeb.BoardLive.BoardEvents`). Call it only after the transaction that
  ended the access has committed. Returns `:ok`.
  """
  @spec notify_derived_access_ended(integer(), integer()) :: :ok
  def notify_derived_access_ended(user_id, organization_id)
      when is_integer(user_id) and is_integer(organization_id) do
    user_id
    |> derived_board_ids_query(organization_id)
    |> Repo.all()
    |> Enum.each(fn board_id ->
      Phoenix.PubSub.broadcast(
        Kanban.PubSub,
        "board:#{board_id}",
        {Kanban.Boards, :members_changed, board_id}
      )
    end)
  end

  defp lock_rows(user_id, workspace_ids) do
    from(bu in BoardUser,
      join: b in Board,
      on: b.id == bu.board_id,
      where: bu.user_id == ^user_id and b.workspace_id in ^workspace_ids,
      order_by: bu.board_id,
      lock: "FOR UPDATE",
      select: {bu, b}
    )
    |> Repo.all()
  end

  defp delete_rows(rows, user_id) do
    row_ids = Enum.map(rows, fn {board_user, _board} -> board_user.id end)
    from(bu in BoardUser, where: bu.id in ^row_ids) |> Repo.delete_all()

    Enum.map(rows, fn {board_user, board} ->
      {revoked, _} = ApiTokens.revoke_user_tokens_for_board(board.id, user_id)
      {board, board_user, revoked}
    end)
  end

  defp derived_board_ids_query(user_id, organization_id) do
    explicit =
      from(bu in BoardUser,
        where: bu.user_id == ^user_id and bu.access in [:owner, :modify],
        select: bu.board_id
      )

    from(b in Board,
      join: w in assoc(b, :workspace),
      where: w.organization_id == ^organization_id and b.id not in subquery(explicit),
      select: b.id
    )
  end

  defp boards_in(workspace_ids) do
    from(b in Board, where: b.workspace_id in ^workspace_ids, select: b.id)
  end

  # Board tokens on the workspaces' boards, and workspace tokens (W2220) of the
  # workspaces themselves.
  defp revoke_remaining_tokens(user_id, workspace_ids) do
    from(t in ApiToken,
      where:
        t.user_id == ^user_id and is_nil(t.revoked_at) and
          (t.board_id in subquery(boards_in(workspace_ids)) or t.workspace_id in ^workspace_ids)
    )
    |> Repo.update_all(set: [revoked_at: DateTime.utc_now(:second)])
  end

  defp unassign_open_tasks(user_id, workspace_ids) do
    from(t in Task,
      join: c in assoc(t, :column),
      where:
        c.board_id in subquery(boards_in(workspace_ids)) and t.assigned_to_id == ^user_id and
          is_nil(t.archived_at)
    )
    |> Repo.update_all(set: [assigned_to_id: nil, updated_at: NaiveDateTime.utc_now(:second)])
  end
end
