defmodule Kanban.SCIM.Groups do
  @moduledoc """
  The SCIM `/Groups` resource of an Organization (W2247): each of the
  Organization's workspaces is a Group, and its members are the workspace's
  members.

  The list shows the Organization's workspaces that are not archived. An
  archived one can still be read and have members removed, but gains none.
  A personal workspace, or one of another Organization, is never found.

  Group membership PATCH adds users as workspace `:member`s (only members of
  the Organization can be added; a guest already in the workspace keeps that
  role) and removes them the way an org-admin's removal does
  (`Kanban.Workspaces.MembershipCascade.remove/2`): their board memberships,
  board and workspace API tokens and open-task assignments in that workspace
  go too. Workspace owners are never removed. Groups are created, renamed and
  archived by org-admins in the org console, never through SCIM.

  A PATCH plans its adds and removes from the members it reads before taking
  the Organization's lock, so of two PATCHes to one Group at the same moment
  the later one wins; the identity provider's next sync sets the members
  again. A change of members moves the Group's `meta.lastModified`.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.AuditLog
  alias Kanban.Organizations.MembershipWrites
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias Kanban.SCIM.Filter
  alias Kanban.SCIM.ListParams
  alias Kanban.SCIM.Patch
  alias Kanban.SCIM.ScimToken
  alias Kanban.Workspaces.InvitationRevocation
  alias Kanban.Workspaces.MembershipCascade
  alias Kanban.Workspaces.Workspace
  alias Kanban.Workspaces.WorkspaceMember

  @max_bigint 9_223_372_036_854_775_807

  @type member :: %{user_id: integer(), email: String.t()}
  @type resource_record :: %{workspace: Workspace.t(), members: [member()] | nil}

  @doc """
  Lists the Organization's active workspaces a page at a time, optionally
  filtered by `displayName eq "..."`. `excludedAttributes=members` leaves the
  members out. Returns `{:ok, %{total:, start_index:, records:}}`.
  """
  @spec list(ScimToken.t(), map()) ::
          {:ok,
           %{total: non_neg_integer(), start_index: pos_integer(), records: [resource_record()]}}
          | {:error, :invalid_filter}
  def list(%ScimToken{organization_id: organization_id}, params) when is_map(params) do
    page = ListParams.parse(params)
    base = where(group_query(organization_id), [w], is_nil(w.archived_at))

    with {:ok, query} <- filtered(base, params["filter"]) do
      {:ok,
       %{
         total: Repo.aggregate(query, :count),
         start_index: page.start_index,
         records: query |> page_workspaces(page) |> to_records(members_wanted?(params))
       }}
    end
  end

  defp page_workspaces(query, page) do
    query
    |> order_by([w], asc: w.id)
    |> offset(^(page.start_index - 1))
    |> limit(^page.count)
    |> Repo.all()
  end

  defp filtered(query, filter) do
    case Filter.parse(filter, ["displayName"]) do
      :none -> {:ok, query}
      {:ok, {"displayName", name}} -> {:ok, where(query, [w], w.name == ^name)}
      {:error, :invalid_filter} = error -> error
    end
  end

  defp members_wanted?(params) do
    excluded =
      params
      |> Map.get("excludedAttributes", "")
      |> to_string()
      |> String.split(",")
      |> Enum.map(&Filter.normalize_attribute/1)

    "members" not in excluded
  end

  @doc "The Organization's workspace with `id`, as a Group, or `{:error, :not_found}`."
  @spec get(ScimToken.t(), term(), map()) :: {:ok, resource_record()} | {:error, :not_found}
  def get(%ScimToken{organization_id: organization_id}, id, params \\ %{}) do
    with {:ok, workspace} <- fetch_workspace(organization_id, id) do
      {:ok, workspace |> List.wrap() |> to_records(members_wanted?(params)) |> hd()}
    end
  end

  defp fetch_workspace(organization_id, id) do
    case parse_id(id) do
      nil ->
        {:error, :not_found}

      workspace_id ->
        organization_id
        |> group_query()
        |> where([w], w.id == ^workspace_id)
        |> Repo.one()
        |> case do
          %Workspace{} = workspace -> {:ok, workspace}
          nil -> {:error, :not_found}
        end
    end
  end

  defp group_query(organization_id) do
    from(w in Workspace, where: w.organization_id == ^organization_id and w.personal == false)
  end

  defp to_records(workspaces, false), do: Enum.map(workspaces, &%{workspace: &1, members: nil})

  defp to_records(workspaces, true) do
    members =
      from(m in WorkspaceMember,
        join: u in User,
        on: u.id == m.user_id,
        where: m.workspace_id in ^Enum.map(workspaces, & &1.id),
        order_by: [asc: m.user_id],
        select: {m.workspace_id, %{user_id: u.id, email: u.email}}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Enum.map(workspaces, &%{workspace: &1, members: Map.get(members, &1.id, [])})
  end

  @doc """
  Applies a Group PATCH: member adds, removes and replacement. A displayName
  that differs from the workspace's name is refused with `:mutability`, and so
  is adding members to an archived workspace. A user who is not a member of
  the Organization is refused with `:invalid_member`, whether or not the
  account exists. Returns `:ok`.
  """
  @spec patch(ScimToken.t(), term(), term()) ::
          :ok
          | {:error, :not_found | :invalid_syntax | :invalid_path | :mutability | :invalid_member}
  def patch(%ScimToken{organization_id: organization_id} = token, id, body) do
    with {:ok, workspace} <- fetch_workspace(organization_id, id),
         {:ok, ops} <- Patch.group_ops(body) do
      patch_workspace(token, workspace, ops)
    end
  end

  defp patch_workspace(token, workspace, ops) do
    with :ok <- check_display_name(ops, workspace),
         {:ok, {to_add, to_remove}} <- plan(ops, member_ids(workspace.id)),
         :ok <- check_archived(workspace, to_add) do
      apply_membership(token, workspace, to_add, to_remove)
    end
  end

  defp check_display_name(ops, workspace) do
    if Enum.all?(ops, &same_name?(&1, workspace)), do: :ok, else: {:error, :mutability}
  end

  defp same_name?({:display_name, name}, workspace), do: name == workspace.name
  defp same_name?(_op, _workspace), do: true

  defp check_archived(%Workspace{archived_at: nil}, _to_add), do: :ok
  defp check_archived(%Workspace{}, []), do: :ok
  defp check_archived(%Workspace{}, _to_add), do: {:error, :mutability}

  defp member_ids(workspace_id) do
    from(m in WorkspaceMember, where: m.workspace_id == ^workspace_id, select: m.user_id)
    |> Repo.all()
    |> MapSet.new()
  end

  # Folds the operations over the current members, so the result does not
  # depend on how a provider splits a change into operations.
  defp plan(ops, current) do
    with {:ok, final} <- fold(ops, current) do
      {:ok,
       {final |> MapSet.difference(current) |> Enum.sort(),
        current |> MapSet.difference(final) |> Enum.sort()}}
    end
  end

  defp fold(ops, current) do
    Enum.reduce_while(ops, {:ok, current}, fn op, {:ok, acc} ->
      case fold_op(op, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        :error -> {:halt, {:error, :invalid_member}}
      end
    end)
  end

  defp fold_op({:add, ids}, acc), do: with_ids(ids, &MapSet.union(acc, &1))
  defp fold_op({:remove, ids}, acc), do: with_ids(ids, &MapSet.difference(acc, &1))
  defp fold_op({:replace, ids}, _acc), do: with_ids(ids, & &1)
  defp fold_op(:remove_all, _acc), do: {:ok, MapSet.new()}
  defp fold_op({:display_name, _name}, acc), do: {:ok, acc}

  defp with_ids(ids, fun) do
    parsed = Enum.map(ids, &parse_id/1)
    if Enum.any?(parsed, &is_nil/1), do: :error, else: {:ok, parsed |> MapSet.new() |> fun.()}
  end

  defp apply_membership(_token, _workspace, [], []), do: :ok

  defp apply_membership(token, workspace, to_add, to_remove) do
    invitations =
      Enum.map(to_remove, &InvitationRevocation.addressed_to(&1, {:workspace, workspace.id}))

    fn -> change_membership(token, workspace, {to_add, to_remove}, invitations) end
    |> Repo.transact()
    |> report(token, workspace)
  end

  defp change_membership(token, workspace, {to_add, to_remove}, invitations) do
    with :ok <- InvitationRevocation.lock(invitations),
         :ok <- MembershipWrites.lock_organization(token.organization_id),
         {:ok, added} <- add_members(workspace, to_add, token.organization_id) do
      {removed_count, removed} = remove_members(workspace, to_remove)
      InvitationRevocation.revoke(invitations)
      touch(workspace, added + removed_count)
      {:ok, {added, removed_count, removed}}
    end
  end

  # Moves the Group's meta.lastModified when its members changed.
  defp touch(_workspace, 0), do: :ok

  defp touch(workspace, _changed) do
    from(w in Workspace, where: w.id == ^workspace.id)
    |> Repo.update_all(set: [updated_at: DateTime.utc_now(:second)])

    :ok
  end

  defp add_members(_workspace, [], _organization_id), do: {:ok, 0}

  defp add_members(workspace, user_ids, organization_id) do
    members =
      from(m in OrganizationMember,
        where: m.organization_id == ^organization_id and m.user_id in ^user_ids,
        select: m.user_id
      )
      |> Repo.all()

    if length(members) == length(user_ids) do
      now = DateTime.utc_now(:second)

      rows =
        Enum.map(user_ids, fn user_id ->
          %{
            workspace_id: workspace.id,
            user_id: user_id,
            role: :member,
            inserted_at: now,
            updated_at: now
          }
        end)

      {added, _} = Repo.insert_all(WorkspaceMember, rows, on_conflict: :nothing)
      {:ok, added}
    else
      {:error, :invalid_member}
    end
  end

  # Owners are never removed through SCIM.
  defp remove_members(_workspace, []), do: {0, []}

  defp remove_members(workspace, user_ids) do
    removable =
      from(m in WorkspaceMember,
        where: m.workspace_id == ^workspace.id and m.user_id in ^user_ids and m.role != :owner,
        lock: "FOR UPDATE",
        select: m.user_id
      )
      |> Repo.all()

    removed = Enum.flat_map(removable, &MembershipCascade.remove(&1, [workspace.id]))

    {count, _} =
      from(m in WorkspaceMember,
        where: m.workspace_id == ^workspace.id and m.user_id in ^removable
      )
      |> Repo.delete_all()

    {count, removed}
  end

  defp report({:ok, {added, removed_count, removed}}, token, workspace) do
    MembershipCascade.broadcast_removed(removed)

    AuditLog.event(:scim_group_updated,
      organization_id: token.organization_id,
      scim_token_id: token.id,
      workspace_id: workspace.id,
      added_count: added,
      removed_count: removed_count
    )

    :ok
  end

  defp report({:error, _reason} = error, _token, _workspace), do: error

  defp parse_id(id) when is_integer(id) and id > 0 and id <= @max_bigint, do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> parse_id(int_id)
      _other -> nil
    end
  end

  defp parse_id(_id), do: nil
end
