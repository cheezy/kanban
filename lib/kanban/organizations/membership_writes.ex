defmodule Kanban.Organizations.MembershipWrites do
  @moduledoc """
  The locked transactions behind the membership functions in
  `Kanban.Organizations`.

  `Kanban.Organizations` checks who is acting and calls these; nothing else
  should, because none of them checks the actor itself.

  Every write first takes a `FOR UPDATE` row lock on the organization and holds
  it until the transaction ends, so writes to one Organization's memberships
  run one at a time and each sees the others' committed result. That is what
  keeps the last-org-admin check in `remove_org_admin/3` true when two
  removals race.

  Telemetry and audit events go through
  `Kanban.Organizations.OrganizationTelemetry` only once the transaction has
  returned `{:ok, _}`. A refusal, an unchanged membership or a rolled-back
  write emits and records nothing.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Organizations.Organization
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Organizations.OrganizationTelemetry
  alias Kanban.Repo

  @typep change :: :created | :promoted | :unchanged | :removed

  @doc """
  Adds `user` to the Organization with `organization_id` as a `:member`. A
  user already in that Organization is returned unchanged; a user in another
  Organization is refused with `:already_in_another_organization`.
  """
  @spec add_member(integer(), User.t()) ::
          {:ok, OrganizationMember.t()}
          | {:error, :already_in_another_organization | :not_found | Ecto.Changeset.t()}
  def add_member(organization_id, %User{} = user) do
    Repo.transact(fn ->
      with :ok <- lock_organization(organization_id) do
        case user_membership(user) do
          nil ->
            insert_membership(organization_id, user, :member)

          %OrganizationMember{organization_id: ^organization_id} = membership ->
            {:ok, {:unchanged, membership}}

          %OrganizationMember{} ->
            {:error, :already_in_another_organization}
        end
      end
    end)
    |> notify(fn change, membership ->
      OrganizationTelemetry.member_added(membership, change, user.id)
    end)
  end

  @doc """
  Makes `user` an org-admin of the Organization with `organization_id`:
  creates the membership, promotes a member of that Organization, or leaves an
  existing org-admin unchanged. A user in another Organization is refused with
  `:already_in_another_organization`. `actor` has already been checked.

  ## Options

    * `:account_created` - `true` when `user`'s account was created for this
      appointment, reported in the telemetry and audit event. Defaults to
      `false`.
  """
  @spec appoint_org_admin(User.t(), integer(), User.t(), [{:account_created, boolean()}]) ::
          {:ok, OrganizationMember.t()}
          | {:error, :already_in_another_organization | :not_found | Ecto.Changeset.t()}
  def appoint_org_admin(%User{} = actor, organization_id, %User{} = user, opts \\ []) do
    account_created = Keyword.get(opts, :account_created, false)

    Repo.transact(fn ->
      with :ok <- lock_organization(organization_id) do
        appoint_in_locked_organization(organization_id, user)
      end
    end)
    |> notify(fn change, membership ->
      OrganizationTelemetry.org_admin_appointed(membership, change, actor, account_created)
    end)
  end

  @doc """
  Deletes `user`'s org-admin membership of the Organization with
  `organization_id`, refusing with `:last_org_admin` when it would leave other
  members with no org-admin and with `:not_found` when `user` is not an
  org-admin there. `actor` has already been checked.
  """
  @spec remove_org_admin(User.t(), integer(), User.t()) ::
          {:ok, OrganizationMember.t()} | {:error, :last_org_admin | :not_found}
  def remove_org_admin(%User{} = actor, organization_id, %User{} = user) do
    Repo.transact(fn ->
      with :ok <- lock_organization(organization_id),
           {:ok, membership} <- fetch_org_admin_membership(organization_id, user),
           :ok <- ensure_not_last_org_admin(membership) do
        delete_membership(membership)
      end
    end)
    |> notify(fn :removed, membership ->
      OrganizationTelemetry.org_admin_removed(membership, actor)
    end)
  end

  defp appoint_in_locked_organization(organization_id, user) do
    case user_membership(user) do
      nil ->
        insert_membership(organization_id, user, :org_admin)

      %OrganizationMember{organization_id: ^organization_id, role: :org_admin} = membership ->
        {:ok, {:unchanged, membership}}

      %OrganizationMember{organization_id: ^organization_id} = membership ->
        promote(membership)

      %OrganizationMember{} ->
        {:error, :already_in_another_organization}
    end
  end

  defp lock_organization(organization_id) do
    from(o in Organization, where: o.id == ^organization_id, select: o.id, lock: "FOR UPDATE")
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      _id -> :ok
    end
  end

  defp user_membership(%User{id: user_id}) do
    from(m in OrganizationMember, where: m.user_id == ^user_id, lock: "FOR UPDATE")
    |> Repo.one()
  end

  defp insert_membership(organization_id, %User{id: user_id}, role) do
    organization_id
    |> OrganizationMember.changeset(user_id, role)
    |> Repo.insert()
    |> case do
      {:ok, membership} -> {:ok, {:created, membership}}
      {:error, changeset} -> {:error, membership_error(changeset)}
    end
  end

  # The lookup found no membership, but a concurrent write gave the user one
  # before this insert ran, and the unique index on user_id refused it.
  defp membership_error(%Ecto.Changeset{errors: errors} = changeset) do
    case Keyword.get(errors, :user_id) do
      {_message, opts} -> unique_violation(opts, changeset)
      nil -> changeset
    end
  end

  defp unique_violation(opts, changeset) do
    if opts[:constraint] == :unique, do: :already_in_another_organization, else: changeset
  end

  defp promote(membership) do
    membership
    |> OrganizationMember.role_changeset(:org_admin)
    |> Repo.update(stale_error_field: :id)
    |> case do
      {:ok, membership} -> {:ok, {:promoted, membership}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp fetch_org_admin_membership(organization_id, %User{id: user_id}) do
    from(m in OrganizationMember,
      where:
        m.organization_id == ^organization_id and m.user_id == ^user_id and
          m.role == ^:org_admin
    )
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      membership -> {:ok, membership}
    end
  end

  # Runs while the organization row is locked, so no other membership write can
  # change the answer before the delete. The other org-admins' rows are locked
  # too, rather than counted: deleting a user removes their membership through
  # the database cascade without taking the organization lock, and a locking
  # read waits for that delete and then skips the row, where a count would
  # still see it.
  defp ensure_not_last_org_admin(%OrganizationMember{} = membership) do
    others =
      from(m in OrganizationMember,
        where: m.organization_id == ^membership.organization_id and m.id != ^membership.id
      )

    other_org_admins =
      others
      |> where([m], m.role == ^:org_admin)
      |> select([m], m.id)
      |> lock("FOR UPDATE")
      |> Repo.all()

    if other_org_admins == [] and Repo.exists?(others),
      do: {:error, :last_org_admin},
      else: :ok
  end

  defp delete_membership(%OrganizationMember{id: id} = membership) do
    case from(m in OrganizationMember, where: m.id == ^id) |> Repo.delete_all() do
      {1, _} -> {:ok, {:removed, membership}}
      {0, _} -> {:error, :not_found}
    end
  end

  # Runs `fun` for a committed change and returns the membership. An unchanged
  # membership and a refusal emit and record nothing.
  @spec notify({:ok, {change(), OrganizationMember.t()}} | {:error, term()}, function()) ::
          {:ok, OrganizationMember.t()} | {:error, term()}
  defp notify({:ok, {:unchanged, membership}}, _fun), do: {:ok, membership}

  defp notify({:ok, {change, membership}}, fun) do
    fun.(change, membership)
    {:ok, membership}
  end

  defp notify({:error, _reason} = error, _fun), do: error
end
