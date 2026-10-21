defmodule Kanban.Workspaces.MembershipCascade do
  @moduledoc """
  What ending someone's place in a workspace does to their boards there.

  Used by `Kanban.Workspaces.remove_member/3` (one workspace) and, through
  `remove_from_organization/2`, by every path that ends an Organization
  membership: `Kanban.Organizations.MemberRemoval` (an ordinary member) and
  `Kanban.Organizations.remove_org_admin/3` (an org-admin). `remove/2` runs
  inside the caller's transaction and, for every board in the given
  workspaces:

    * deletes the user's `board_users` row,
    * revokes the user's API tokens for the board, and their workspace tokens
      for the workspace (W2220), so an agent acting through one loses access at
      once, and
    * returns the user's claimed tasks to Ready (`Kanban.Tasks.ClaimRelease`)
      and unassigns them from the board's other open (unarchived) tasks, as
      `Kanban.Boards.MembershipChanges.remove_user_from_board/3` does, and
    * disables the webhook endpoints the user created on the board, unless
      they can still open it as an org-admin
      (`Kanban.Webhooks.pause_former_member_endpoints/2`).

  The user's **owner** row is deleted too. `remove_user_from_board/3` refuses
  that, because a board without an owner in a personal workspace would be seen
  by nobody. These boards are in org workspaces, which the Organization's
  org-admins always reach through derived access
  (`Kanban.Workspaces.Policy`), so the board is never stranded, and keeping
  the row would leave a removed member with owner access. A board left without
  an owner row is managed by the org-admins.

  `notify/3` reports each removed row once the transaction has committed, in
  the same way `remove_user_from_board/3` does.

  `remove_from_organization/2` also deletes the user's `workspace_members`
  rows in every workspace of the Organization, so rejoining it later never
  brings old access back (design doc §4.4), and disables every webhook
  endpoint they created on the Organization's boards, an org-admin's
  included. A removed org-admin also loses
  derived access to boards they held no row on, so
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
  alias Kanban.Tasks.ClaimRelease
  alias Kanban.Tasks.Task
  alias Kanban.Webhooks
  alias Kanban.Workspaces.Workspace
  alias Kanban.Workspaces.WorkspaceMember

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
    Webhooks.pause_former_member_endpoints(user_id, boards_in(workspace_ids))
    ClaimRelease.release(user_id, boards_in(workspace_ids))
    unassign_open_tasks(user_id, workspace_ids)
    removed
  end

  @doc """
  Ends `user_id`'s place in every workspace of `organization_id`, archived
  ones included: runs `remove/2` on all of them and deletes the user's
  `workspace_members` rows there. Call it inside the transaction that ends the
  user's Organization membership, after taking the Organization's row lock.
  Boards in personal workspaces and in other Organizations are left alone.

  Returns what `remove/2` returns, to pass to `notify/3` after commit.
  """
  @spec remove_from_organization(integer(), integer()) :: removed()
  def remove_from_organization(user_id, organization_id)
      when is_integer(user_id) and is_integer(organization_id) do
    workspace_ids =
      from(w in Workspace, where: w.organization_id == ^organization_id, select: w.id)
      |> Repo.all()

    removed = remove(user_id, workspace_ids)
    Webhooks.pause_creator_endpoints(user_id, boards_in(workspace_ids))

    from(m in WorkspaceMember,
      where: m.user_id == ^user_id and m.workspace_id in ^workspace_ids
    )
    |> Repo.delete_all()

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
  Tells each board `remove/2` removed a membership from that its members
  changed, by broadcasting `{Kanban.Boards, :members_changed, board_id}` on
  `"board:<id>"`, so an open board page re-reads the viewer's access. The
  actor-less form of `notify/3`, for removals no user made (SCIM
  deprovisioning, W2247): it sends no notification and emits no membership
  telemetry. Call it only after the transaction has committed. Returns `:ok`.
  """
  @spec broadcast_removed(removed()) :: :ok
  def broadcast_removed(removed) when is_list(removed) do
    Enum.each(removed, fn {board, _board_user, _revoked} ->
      Phoenix.PubSub.broadcast(
        Kanban.PubSub,
        "board:#{board.id}",
        {Kanban.Boards, :members_changed, board.id}
      )
    end)
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
