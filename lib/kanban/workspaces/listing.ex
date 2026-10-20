defmodule Kanban.Workspaces.Listing do
  @moduledoc """
  The reads behind workspace settings (`/workspace/settings`): a workspace's
  members, its boards, and the boards an org-admin may move into it.

  Exposed through `Kanban.Workspaces` via `defdelegate`. Each function re-reads
  the workspace through `Kanban.Workspaces.get_workspace/2`, so a workspace the
  actor cannot reach, or a personal one, gives an empty list rather than its
  contents.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Repo
  alias Kanban.Workspaces
  alias Kanban.Workspaces.Policy
  alias Kanban.Workspaces.Workspace
  alias Kanban.Workspaces.WorkspaceMember

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
