defmodule Kanban.Workspaces.Listing do
  @moduledoc """
  The workspace reads: the org workspaces a user can reach (the workspace
  switcher, `Kanban.Workspaces.Current`), and the reads behind workspace
  settings (`/workspace/settings`): a workspace's members, its boards, and the
  boards an org-admin may move into it.

  Exposed through `Kanban.Workspaces` via `defdelegate`. Each settings read
  re-reads the workspace through `Kanban.Workspaces.get_workspace/2`, so a
  workspace the actor cannot reach, or a personal one, gives an empty list
  rather than its contents. A disabled account reaches no workspace.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Organizations
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias Kanban.Workspaces
  alias Kanban.Workspaces.Policy
  alias Kanban.Workspaces.Workspace
  alias Kanban.Workspaces.WorkspaceMember

  @doc """
  Returns the org workspaces `user` can reach, unarchived, by name ignoring case.

  An org-admin gets every unarchived workspace of their Organization; anyone
  else gets the ones they have a member or guest row on. A personal workspace is
  never returned, not even the user's own, and a disabled account, read from
  the database, gets none.
  """
  @spec list_workspaces_for_user(User.t()) :: [Workspace.t()]
  def list_workspaces_for_user(%User{} = user),
    do: list_workspaces_for_membership(user, Organizations.get_membership(user))

  @doc """
  `list_workspaces_for_user/1` for a caller that has already loaded `user`'s
  Organization membership (or `nil`), saving that query. Whether the account is
  enabled is still read from the database, in the same query as the workspaces.
  """
  @spec list_workspaces_for_membership(User.t(), OrganizationMember.t() | nil) :: [Workspace.t()]
  def list_workspaces_for_membership(%User{} = user, membership) do
    case membership do
      %OrganizationMember{role: :org_admin, organization_id: organization_id} ->
        organization_id |> org_workspaces_query(user) |> Repo.all()

      %OrganizationMember{organization_id: organization_id} ->
        organization_id
        |> org_workspaces_query(user)
        |> join(:inner, [w], m in assoc(w, :members), on: m.user_id == ^user.id)
        |> Repo.all()

      nil ->
        []
    end
  end

  # The joined user row is the enabled check: a disabled account matches none.
  defp org_workspaces_query(organization_id, %User{id: user_id}) do
    from(w in Workspace,
      join: u in User,
      on: u.id == ^user_id and is_nil(u.disabled_at),
      where:
        w.organization_id == ^organization_id and w.personal == false and is_nil(w.archived_at),
      order_by: [asc: fragment("lower(?)", w.name), asc: w.id]
    )
  end

  @doc """
  Returns the member and guest rows of the org workspace `workspace`, each with
  its user preloaded, ordered by email. Empty when `actor` cannot reach the
  workspace or it is personal.
  """
  @spec list_members(User.t(), Workspace.t() | integer() | String.t()) :: [WorkspaceMember.t()]
  def list_members(%User{} = actor, workspace) do
    case reachable_org_workspace(actor, workspace) do
      %Workspace{id: workspace_id} ->
        from(m in WorkspaceMember,
          join: u in assoc(m, :user),
          where: m.workspace_id == ^workspace_id,
          order_by: [asc: u.email, asc: m.id],
          preload: [user: u]
        )
        |> Repo.all()

      nil ->
        []
    end
  end

  @doc """
  Returns the boards in the org workspace `workspace` that `actor` has
  effective access to, by name. An org-admin of its Organization sees every
  board in it; a member or guest only the boards they reach through
  `board_users`, so no other board's name is shown. Empty when `actor` cannot
  reach the workspace or it is personal.
  """
  @spec list_boards(User.t(), Workspace.t() | integer() | String.t()) :: [Board.t()]
  def list_boards(%User{} = actor, workspace) do
    case reachable_org_workspace(actor, workspace) do
      %Workspace{id: workspace_id} ->
        actor
        |> Policy.list_accessible_boards(workspace_id: workspace_id)
        |> Enum.sort_by(&{String.downcase(&1.name || ""), &1.id})

      nil ->
        []
    end
  end

  @doc """
  Returns the boards `actor` could move into an org workspace: those in their
  personal workspace on which they hold a `board_users` owner row, by name.
  A board the W2217 backfill placed in their personal workspace without an
  owner row for them is not listed.
  """
  @spec list_movable_boards(User.t()) :: [Board.t()]
  def list_movable_boards(%User{id: user_id}) do
    from(b in Board,
      join: w in assoc(b, :workspace),
      join: m in WorkspaceMember,
      on: m.workspace_id == w.id and m.user_id == ^user_id and m.role == ^:owner,
      join: bu in BoardUser,
      on: bu.board_id == b.id and bu.user_id == ^user_id and bu.access == ^:owner,
      where: w.personal == true,
      order_by: [asc: fragment("lower(?)", b.name), asc: b.id],
      select: %{b | user_access: :owner}
    )
    |> Repo.all()
  end

  defp reachable_org_workspace(actor, %Workspace{id: id}), do: reachable_org_workspace(actor, id)

  defp reachable_org_workspace(actor, id) do
    case Workspaces.get_workspace(id, actor) do
      %Workspace{personal: false} = workspace -> workspace
      _other -> nil
    end
  end
end
