defmodule Kanban.Boards.OrgBoardMembers do
  @moduledoc """
  Who may hold a membership on a board in an Organization workspace: only a
  current member of that Organization, in either role.

  `Kanban.Boards.MembershipChanges` asks `lock_and_check/3` before every
  board-user insert, the owner's direct add and an invitation's board grant
  alike. Without it a board owner could add an ex-member straight back after
  an org-admin removed them, or a member of another Organization, with no
  `:org_member_added` audit. People outside the Organization join through a
  workspace invitation (`Kanban.Workspaces.Invitations`), which adds the
  Organization membership first. Boards in personal workspaces are not
  checked.

  The Organization row is locked before the board row, the order invitation
  acceptance and Organization removal take them, so the add cannot land
  between a member's removal and its commit.
  """

  import Ecto.Query, only: [from: 2]

  alias Kanban.Boards.Board
  alias Kanban.Organizations.Organization
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Workspaces.Workspace

  @doc """
  Locks the board's Organization row (when its workspace belongs to one) and
  then the board row, and checks that `user_id` is a member of that
  Organization. Call it inside a transaction, with the `repo` it runs on.

  Returns `{:ok, organization_id}` (`nil` for a personal-workspace board),
  `{:error, :not_org_member}` when the user belongs to no Organization or to
  another one, `{:error, :not_found}` when the board is gone, and
  `{:error, :board_moved}` when the board moved to another workspace's
  Organization between the first read and the board lock.
  """
  @spec lock_and_check(Ecto.Repo.t(), integer(), integer()) ::
          {:ok, integer() | nil} | {:error, :not_org_member | :not_found | :board_moved}
  def lock_and_check(repo, board_id, user_id) do
    with {:ok, organization_id} <- board_organization_id(repo, board_id, false),
         :ok <- lock_organization(repo, organization_id),
         {:ok, locked_organization_id} <- board_organization_id(repo, board_id, true),
         :ok <- same_organization(organization_id, locked_organization_id) do
      check_member(repo, organization_id, user_id)
    end
  end

  # With lock? the board row alone is locked, then its workspace is read; the
  # workspace row itself is left unlocked.
  defp board_organization_id(repo, board_id, lock?) do
    board_query = from(b in Board, where: b.id == ^board_id, select: b.workspace_id)
    board_query = if lock?, do: from(b in board_query, lock: "FOR UPDATE"), else: board_query

    case repo.one(board_query) do
      nil -> {:error, :not_found}
      workspace_id -> {:ok, workspace_organization_id(repo, workspace_id)}
    end
  end

  defp workspace_organization_id(repo, workspace_id) do
    from(w in Workspace, where: w.id == ^workspace_id, select: w.organization_id)
    |> repo.one()
  end

  defp lock_organization(_repo, nil), do: :ok

  defp lock_organization(repo, organization_id) do
    from(o in Organization,
      where: o.id == ^organization_id,
      select: o.id,
      lock: "FOR UPDATE"
    )
    |> repo.one()
    |> case do
      nil -> {:error, :not_found}
      _id -> :ok
    end
  end

  defp same_organization(organization_id, organization_id), do: :ok
  defp same_organization(_before, _after), do: {:error, :board_moved}

  defp check_member(_repo, nil, _user_id), do: {:ok, nil}

  defp check_member(repo, organization_id, user_id) do
    member_query =
      from(m in OrganizationMember,
        where: m.organization_id == ^organization_id and m.user_id == ^user_id
      )

    if repo.exists?(member_query),
      do: {:ok, organization_id},
      else: {:error, :not_org_member}
  end
end
