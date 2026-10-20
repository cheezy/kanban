defmodule Kanban.Workspaces.InvitationRevocation do
  @moduledoc """
  Revokes open workspace invitations when a membership change makes them
  stale, so accepting one later cannot undo the change:

    * removal from an Organization (`Kanban.Organizations.MemberRemoval`, and
      `Kanban.Organizations.remove_org_admin/3` for an org-admin) revokes the
      invitations addressed to the user in every workspace of the
      Organization;
    * removal from a workspace (`Kanban.Workspaces.remove_member/3`) and a
      downgrade to `:guest` (`Kanban.Workspaces.update_member_role/4`) revoke
      the ones addressed to the user in that workspace;
    * removing an org-admin also revokes the invitations they sent in the
      Organization, which would otherwise come back to life if they were
      appointed again.

  An invitation is addressed to a user when its email is the user's address,
  ignoring case and surrounding space, or when the user registered through it
  (`registered_user_id`).

  Acceptance locks the invitation row before the Organization row and the
  workspace member row, so the caller locks the rows with `lock/1` at the
  start of its transaction, before it takes any of those locks, and revokes
  them with `revoke/1` once the change is made. Taking the locks in the other
  order would let a removal and an acceptance deadlock.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Repo
  alias Kanban.Workspaces.Invitation
  alias Kanban.Workspaces.Workspace

  @doc """
  Open invitations addressed to the user with `user_id`, in the workspaces
  `scope` names: `{:organization, id}` for every workspace of an Organization,
  archived ones included, or `{:workspace, id}` for one workspace.
  """
  @spec addressed_to(integer(), {:organization | :workspace, integer()}) :: Ecto.Query.t()
  def addressed_to(user_id, scope) when is_integer(user_id) do
    email = user_id |> user_email() |> Invitation.normalize_email()

    from(i in Invitation.open_query(),
      where: i.workspace_id in subquery(workspace_ids(scope)),
      where: i.registered_user_id == ^user_id or i.email == ^(email || "")
    )
  end

  @doc """
  Open invitations the user with `user_id` sent in the workspaces of the
  Organization `organization_id`.
  """
  @spec sent_by(integer(), integer()) :: Ecto.Query.t()
  def sent_by(user_id, organization_id) when is_integer(user_id) do
    from(i in Invitation.open_query(),
      where: i.invited_by_id == ^user_id,
      where: i.workspace_id in subquery(workspace_ids({:organization, organization_id}))
    )
  end

  @doc """
  Locks the invitations each query matches, in id order. Call it inside the
  transaction, before the Organization or workspace member locks. Returns
  `:ok`.
  """
  @spec lock([Ecto.Query.t()]) :: :ok
  def lock(queries) when is_list(queries) do
    queries
    |> Enum.flat_map(fn query ->
      query |> select([i], i.id) |> Repo.all()
    end)
    |> Enum.uniq()
    |> Enum.sort()
    |> case do
      [] ->
        :ok

      ids ->
        from(i in Invitation, where: i.id in ^ids, order_by: i.id, lock: "FOR UPDATE")
        |> select([i], i.id)
        |> Repo.all()

        :ok
    end
  end

  @doc """
  Revokes every invitation the queries match. Call it inside the transaction
  that made the change. Returns the number revoked.
  """
  @spec revoke([Ecto.Query.t()]) :: non_neg_integer()
  def revoke(queries) when is_list(queries) do
    now = DateTime.utc_now(:second)

    Enum.reduce(queries, 0, fn query, total ->
      {count, _} = Repo.update_all(query, set: [revoked_at: now, updated_at: now])
      total + count
    end)
  end

  defp workspace_ids({:organization, organization_id}),
    do: from(w in Workspace, where: w.organization_id == ^organization_id, select: w.id)

  defp workspace_ids({:workspace, workspace_id}),
    do: from(w in Workspace, where: w.id == ^workspace_id, select: w.id)

  defp user_email(user_id) do
    from(u in User, where: u.id == ^user_id, select: u.email) |> Repo.one()
  end
end
