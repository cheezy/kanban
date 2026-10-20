defmodule Kanban.Organizations.MemberRemoval do
  @moduledoc """
  An org-admin removing an ordinary member from their Organization, from the
  Members section of the org console (`/org`).

  Only an enabled org-admin of the Organization may remove, and only a
  `:member`: an org-admin is never removed here, so nothing in this module can
  grant or remove org-admin (that stays with site admins). The removal runs in
  one transaction that takes the Organization's row lock, the lock every
  membership write in `Kanban.Organizations.MembershipWrites` takes, and in
  every workspace of the Organization — archived ones included — it:

    * deletes the member's board memberships, revokes their API tokens and
      unassigns their open tasks, and
    * deletes their `workspace_members` rows, so rejoining later never brings
      old access back
      (`Kanban.Workspaces.MembershipCascade.remove_from_organization/2`, the
      cascade `Kanban.Organizations.remove_org_admin/3` runs too),

  and then deletes their Organization membership. Boards in personal
  workspaces are left alone: a member keeps access to boards shared with them
  outside the Organization.

  After commit, each removed board membership is reported as
  `Kanban.Boards.remove_user_from_board/3` reports one, and the removal emits
  `[:kanban, :organization, :member_removed]` and records the
  `:org_member_removed` audit event
  (`Kanban.Organizations.OrganizationTelemetry.org_member_removed/2`).

  Kept out of `Kanban.Organizations`, which is over the module size guideline;
  the console calls it directly, as it calls `Kanban.Organizations.OrgWorkspaces`.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Organizations
  alias Kanban.Organizations.MembershipWrites
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Organizations.OrganizationTelemetry
  alias Kanban.Repo
  alias Kanban.Workspaces.MembershipCascade

  @max_bigint 9_223_372_036_854_775_807

  @type error :: :unauthorized | :not_found | :org_admin

  @doc """
  Removes the user with `member_user_id` from the Organization with
  `organization_id`, cascading as the moduledoc describes.

  Returns `{:ok, membership}` with the deleted membership, or:

    * `{:error, :unauthorized}` — `actor` is not an enabled org-admin of the
      Organization, read from the database under the lock.
    * `{:error, :not_found}` — no such Organization, or the user is not a member
      of it (including a user in another Organization, or an id that cannot
      name a row).
    * `{:error, :org_admin}` — the user is an org-admin, who is never removed
      here.

  A refusal changes nothing.

  ## Examples

      iex> remove_member(org_admin, organization.id, member.id)
      {:ok, %OrganizationMember{role: :member}}

      iex> remove_member(org_admin, organization.id, other_org_admin.id)
      {:error, :org_admin}

  """
  @spec remove_member(User.t(), integer(), integer() | String.t()) ::
          {:ok, OrganizationMember.t()} | {:error, error()}
  def remove_member(%User{} = actor, organization_id, member_user_id)
      when is_integer(organization_id) do
    case parse_id(member_user_id) do
      nil ->
        {:error, :not_found}

      user_id ->
        fn -> remove_locked(actor, organization_id, user_id) end
        |> Repo.transaction()
        |> report(actor)
    end
  end

  defp remove_locked(actor, organization_id, user_id) do
    with :ok <- MembershipWrites.lock_organization(organization_id),
         :ok <- check_org_admin(actor, organization_id),
         {:ok, membership} <- lock_membership(organization_id, user_id),
         :ok <- check_ordinary_member(membership) do
      remove_from_organization(membership, organization_id, user_id)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp remove_from_organization(membership, organization_id, user_id) do
    removed = MembershipCascade.remove_from_organization(user_id, organization_id)

    case Repo.delete(membership) do
      {:ok, deleted} -> {deleted, removed}
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp check_org_admin(actor, organization_id) do
    if Organizations.org_admin?(actor, organization_id), do: :ok, else: {:error, :unauthorized}
  end

  defp lock_membership(organization_id, user_id) do
    from(m in OrganizationMember,
      where: m.organization_id == ^organization_id and m.user_id == ^user_id,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
    |> case do
      %OrganizationMember{} = membership -> {:ok, membership}
      nil -> {:error, :not_found}
    end
  end

  defp check_ordinary_member(%OrganizationMember{role: :member}), do: :ok
  defp check_ordinary_member(%OrganizationMember{}), do: {:error, :org_admin}

  defp report({:ok, {membership, removed}}, actor) do
    case Accounts.get_user(membership.user_id) do
      %User{} = user -> MembershipCascade.notify(removed, user, actor)
      nil -> :ok
    end

    OrganizationTelemetry.org_member_removed(membership, actor)
    {:ok, membership}
  end

  defp report({:error, reason}, _actor), do: {:error, reason}

  defp parse_id(id) when is_integer(id) and id > 0 and id <= @max_bigint, do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> parse_id(int_id)
      _ -> nil
    end
  end

  defp parse_id(_id), do: nil
end
