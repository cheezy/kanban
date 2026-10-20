defmodule Kanban.Workspaces.Members do
  @moduledoc """
  Membership of org workspaces: adding a member, changing their role between
  `:member` and `:guest`, and removing them. Every call is gated on the actor
  being an org-admin of the workspace's Organization, read from the database.

  Exposed through the `Kanban.Workspaces` facade via `defdelegate` — call these
  as `Workspaces.add_member/4` and so on.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Organizations
  alias Kanban.Repo
  alias Kanban.Workspaces.InvitationRevocation
  alias Kanban.Workspaces.MembershipCascade
  alias Kanban.Workspaces.Workspace
  alias Kanban.Workspaces.WorkspaceMember

  @max_bigint 9_223_372_036_854_775_807
  @assignable_roles [:member, :guest]

  @typedoc "A workspace, or its id as an integer or a string from a URL or form."
  @type workspace_ref :: Workspace.t() | integer() | String.t()

  @type member_error ::
          :unauthorized | :invalid_role | :not_in_organization | :not_found | :archived

  @doc """
  Adds `user` to the org workspace `workspace` as a `:member` or `:guest`.

  `actor` must be an org-admin of the workspace's Organization, and `user` must
  belong to that Organization. The owner role is refused: org workspaces have
  no owner row. A personal workspace takes no members, and looks the same as
  one `actor` may not manage. An archived workspace takes no new members and
  returns `{:error, :archived}`.

  `workspace` is a `%Workspace{}` or its id; it is re-read from the database.
  An id that is not a positive integer that fits the column is refused like a
  missing workspace.

  ## Examples

      iex> add_member(org_admin, workspace, colleague, :member)
      {:ok, %WorkspaceMember{role: :member}}

      iex> add_member(org_admin, workspace, outsider, :guest)
      {:error, :not_in_organization}

  """
  @spec add_member(User.t(), workspace_ref(), User.t(), atom()) ::
          {:ok, WorkspaceMember.t()} | {:error, member_error() | Ecto.Changeset.t()}
  def add_member(%User{} = actor, workspace, %User{} = user, role) do
    with :ok <- check_assignable_role(role),
         {:ok, workspace} <- fetch_managed_workspace(actor, workspace),
         :ok <- check_not_archived(workspace),
         :ok <- check_in_organization(user, workspace) do
      workspace.id
      |> WorkspaceMember.changeset(user.id, role)
      |> Repo.insert()
    end
  end

  @doc """
  Changes `user`'s role on the org workspace `workspace` to `:member` or
  `:guest`. `actor` must be an org-admin of its Organization. Lowering a
  `:member` to `:guest` revokes the open invitations addressed to `user` in
  this workspace (`Kanban.Workspaces.InvitationRevocation`), so accepting one
  later cannot raise them back.

  `workspace` is a `%Workspace{}` or its id; it is re-read from the database,
  and an id that cannot name a row is refused like a missing workspace.
  """
  @spec update_member_role(User.t(), workspace_ref(), User.t(), atom()) ::
          {:ok, WorkspaceMember.t()} | {:error, member_error() | Ecto.Changeset.t()}
  def update_member_role(%User{} = actor, workspace, %User{} = user, role) do
    with :ok <- check_assignable_role(role),
         {:ok, workspace} <- fetch_managed_workspace(actor, workspace),
         {:ok, membership} <- fetch_membership(workspace, user) do
      membership
      |> role_change_invitations(role, workspace, user)
      |> change_role(membership, role)
    end
  end

  # The invitations are locked before the membership row is written,
  # acceptance's lock order, and revoked only once the change is saved.
  defp change_role(invitations, membership, role) do
    Repo.transact(fn ->
      InvitationRevocation.lock(invitations)

      with {:ok, updated} <- membership |> WorkspaceMember.role_changeset(role) |> Repo.update() do
        InvitationRevocation.revoke(invitations)
        {:ok, updated}
      end
    end)
  end

  # Only a member lowered to guest has invitations revoked: re-saving a guest
  # keeps an invitation an org-admin sent to raise them.
  defp role_change_invitations(%WorkspaceMember{role: :member}, :guest, workspace, user),
    do: [InvitationRevocation.addressed_to(user.id, {:workspace, workspace.id})]

  defp role_change_invitations(_membership, _role, _workspace, _user), do: []

  @doc """
  Removes `user` from the org workspace `workspace`. `actor` must be an
  org-admin of its Organization. A user who has since left the Organization can
  still be removed.

  In the same transaction it deletes `user`'s board memberships on this
  workspace's boards — an owner row included — revokes their API tokens for
  those boards and unassigns their open tasks there
  (`Kanban.Workspaces.MembershipCascade`), and revokes the open invitations
  addressed to `user` in this workspace
  (`Kanban.Workspaces.InvitationRevocation`). Boards in other workspaces are
  left alone. Each removed board membership is reported after commit as
  `Kanban.Boards.remove_user_from_board/3` reports one.

  `workspace` is a `%Workspace{}` or its id; it is re-read from the database,
  and an id that cannot name a row is refused like a missing workspace.
  """
  @spec remove_member(User.t(), workspace_ref(), User.t()) ::
          {:ok, WorkspaceMember.t()} | {:error, member_error() | Ecto.Changeset.t()}
  def remove_member(%User{} = actor, workspace, %User{} = user) do
    with {:ok, workspace} <- fetch_managed_workspace(actor, workspace),
         {:ok, membership} <- fetch_membership(workspace, user) do
      fn -> remove_membership(membership, workspace, user) end
      |> Repo.transaction()
      |> notify_removed(user, actor)
    end
  end

  # The invitations are locked first, before the membership rows, the order
  # acceptance takes them in.
  defp remove_membership(membership, workspace, user) do
    invitations = [InvitationRevocation.addressed_to(user.id, {:workspace, workspace.id})]
    InvitationRevocation.lock(invitations)
    removed = MembershipCascade.remove(user.id, [workspace.id])
    InvitationRevocation.revoke(invitations)

    case Repo.delete(membership) do
      {:ok, deleted} -> {deleted, removed}
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp notify_removed({:ok, {deleted, removed}}, user, actor) do
    MembershipCascade.notify(removed, user, actor)
    {:ok, deleted}
  end

  defp notify_removed({:error, _reason} = error, _user, _actor), do: error

  defp check_assignable_role(role) when role in @assignable_roles, do: :ok
  defp check_assignable_role(_role), do: {:error, :invalid_role}

  # Role changes and removals stay allowed on an archived workspace, so its
  # members can still be tidied up; only new members are refused.
  defp check_not_archived(%Workspace{archived_at: nil}), do: :ok
  defp check_not_archived(%Workspace{}), do: {:error, :archived}

  # The workspace is re-read so a stale or hand-built struct cannot point the
  # check at another Organization. A missing workspace, a personal one, and one
  # whose Organization `actor` is not an org-admin of all give the same error,
  # and so does an id that cannot name a row.
  defp fetch_managed_workspace(actor, workspace) do
    case get_by_id(workspace_id(workspace)) do
      %Workspace{personal: false, organization_id: organization_id} = workspace ->
        if Organizations.org_admin?(actor, organization_id),
          do: {:ok, workspace},
          else: {:error, :unauthorized}

      _missing_or_personal ->
        {:error, :unauthorized}
    end
  end

  defp check_in_organization(user, %Workspace{organization_id: organization_id}) do
    if Organizations.member?(user, organization_id),
      do: :ok,
      else: {:error, :not_in_organization}
  end

  defp fetch_membership(%Workspace{id: workspace_id}, %User{id: user_id}) do
    case Repo.get_by(WorkspaceMember, workspace_id: workspace_id, user_id: user_id) do
      %WorkspaceMember{} = membership -> {:ok, membership}
      nil -> {:error, :not_found}
    end
  end

  defp get_by_id(nil), do: nil
  defp get_by_id(id), do: Repo.get(Workspace, id)

  defp workspace_id(%Workspace{id: id}), do: id
  defp workspace_id(id), do: parse_id(id)

  # Ecto.Type.cast(:id, _) accepts nil and integers past bigint, and Repo.get/2
  # raises on both, so a URL-supplied id is bounded here before it is queried.
  defp parse_id(id) when is_integer(id) and id > 0 and id <= @max_bigint, do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> parse_id(int_id)
      _ -> nil
    end
  end

  defp parse_id(_id), do: nil
end
