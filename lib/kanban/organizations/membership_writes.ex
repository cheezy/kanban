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

  The check counts only **enabled** org-admins: a disabled account cannot sign
  in, so it cannot run the Organization. `ensure_not_last_working_org_admin/1`
  applies the same check, under the same lock, when a site admin disables or
  deletes a user.

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
  alias Kanban.Workspaces.MembershipCascade

  @typep change :: :created | :promoted | :unchanged

  @doc """
  Adds `user` to the Organization with `organization_id` as a `:member`. A
  user already in that Organization is returned unchanged; a user in another
  Organization is refused with `:already_in_another_organization`, and a
  disabled account with `:user_disabled`, read from the database under the
  lock. The disabled check comes first, as in `appoint_org_admin/4`, so a
  member who was disabled later is refused too rather than returned
  unchanged.
  """
  @spec add_member(integer(), User.t()) ::
          {:ok, OrganizationMember.t()}
          | {:error,
             :already_in_another_organization | :user_disabled | :not_found | Ecto.Changeset.t()}
  def add_member(organization_id, %User{} = user) do
    Repo.transact(fn ->
      with :ok <- lock_organization(organization_id),
           :ok <- ensure_enabled(user) do
        add_in_locked_organization(organization_id, user)
      end
    end)
    |> notify(fn change, membership ->
      OrganizationTelemetry.member_added(membership, change, user.id)
    end)
  end

  defp add_in_locked_organization(organization_id, user) do
    case user_membership(user) do
      nil ->
        insert_membership(organization_id, user, :member)

      %OrganizationMember{organization_id: ^organization_id} = membership ->
        {:ok, {:unchanged, membership}}

      %OrganizationMember{} ->
        {:error, :already_in_another_organization}
    end
  end

  @doc """
  Makes `user` an org-admin of the Organization with `organization_id`:
  creates the membership, promotes a member of that Organization, or leaves an
  existing org-admin unchanged. A user in another Organization is refused with
  `:already_in_another_organization`, and a disabled account with
  `:user_disabled`, read from the database under the lock. `actor` has already
  been checked.

  ## Options

    * `:account_created` - `true` when `user`'s account was created for this
      appointment, reported in the telemetry and audit event. Defaults to
      `false`.
  """
  @spec appoint_org_admin(User.t(), integer(), User.t(), [{:account_created, boolean()}]) ::
          {:ok, OrganizationMember.t()}
          | {:error,
             :already_in_another_organization | :user_disabled | :not_found | Ecto.Changeset.t()}
  def appoint_org_admin(%User{} = actor, organization_id, %User{} = user, opts \\ []) do
    account_created = Keyword.get(opts, :account_created, false)

    Repo.transact(fn ->
      with :ok <- lock_organization(organization_id),
           :ok <- ensure_enabled(user) do
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

  Ending the membership cascades as removing an ordinary member does
  (`Kanban.Workspaces.MembershipCascade.remove_from_organization/2`), in the
  same transaction and before the membership is deleted: in every workspace of
  the Organization, archived ones included, the user's `board_users` rows are
  deleted, their board and workspace API tokens revoked, their open tasks
  unassigned and their `workspace_members` rows deleted, so being added again
  later never brings old access back. Their personal boards and boards
  shared with them outside the Organization are kept. Once it commits, each
  removed board membership is reported as
  `Kanban.Boards.remove_user_from_board/3` reports one, and the Organization's
  boards' open pages are told to re-read the viewer's access
  (`Kanban.Workspaces.MembershipCascade.notify_derived_access_ended/2`).
  """
  @spec remove_org_admin(User.t(), integer(), User.t()) ::
          {:ok, OrganizationMember.t()} | {:error, :last_org_admin | :not_found}
  def remove_org_admin(%User{} = actor, organization_id, %User{} = user) do
    fn -> remove_org_admin_locked(organization_id, user) end
    |> Repo.transact()
    |> report_org_admin_removed(actor, user)
  end

  # Runs only once the removal has committed.
  defp report_org_admin_removed({:ok, {membership, removed}}, actor, user) do
    OrganizationTelemetry.org_admin_removed(membership, actor)
    MembershipCascade.notify(removed, user, actor)
    MembershipCascade.notify_derived_access_ended(user.id, membership.organization_id)
    {:ok, membership}
  end

  defp report_org_admin_removed({:error, _reason} = error, _actor, _user), do: error

  defp remove_org_admin_locked(organization_id, user) do
    with :ok <- lock_organization(organization_id),
         {:ok, membership} <- fetch_org_admin_membership(organization_id, user),
         :ok <- ensure_not_last_org_admin(membership) do
      removed = MembershipCascade.remove_from_organization(user.id, organization_id)

      case delete_membership(membership) do
        {:ok, {:removed, deleted}} -> {:ok, {deleted, removed}}
        {:error, _reason} = error -> error
      end
    end
  end

  @doc """
  Returns `{:error, :last_org_admin}` when `user` is an enabled org-admin whose
  Organization has other members and no other enabled org-admin, else `:ok`.

  Call it inside the transaction that disables or deletes `user`. It locks the
  Organization row, as every membership write does, and the lock is held until
  that transaction ends, so a concurrent removal, disable or delete of the
  Organization's other org-admin waits and then sees this one's result. A user
  who is already disabled, or no org-admin, passes: disabling or deleting them
  leaves the number of working org-admins as it was.
  """
  @spec ensure_not_last_working_org_admin(User.t()) :: :ok | {:error, :last_org_admin}
  def ensure_not_last_working_org_admin(%User{} = user) do
    case enabled_org_admin_organization_id(user) do
      nil -> :ok
      organization_id -> check_locked_organization(organization_id, user)
    end
  end

  defp enabled_org_admin_organization_id(%User{id: user_id}) do
    from(m in OrganizationMember,
      where:
        m.user_id == ^user_id and m.role == ^:org_admin and
          m.user_id in subquery(enabled_user_ids()),
      select: m.organization_id
    )
    |> Repo.one()
  end

  # The membership is read again under the lock, since it may have been
  # removed while this transaction waited for it.
  defp check_locked_organization(organization_id, user) do
    with :ok <- lock_organization(organization_id),
         {:ok, membership} <- fetch_org_admin_membership(organization_id, user) do
      ensure_not_last_org_admin(membership)
    else
      {:error, :not_found} -> :ok
    end
  end

  # A user whose row is gone passes here; the insert's foreign key refuses it.
  defp ensure_enabled(%User{id: user_id}) do
    disabled_query = from(u in User, where: u.id == ^user_id, select: not is_nil(u.disabled_at))

    case Repo.one(disabled_query) do
      true -> {:error, :user_disabled}
      _enabled_or_gone -> :ok
    end
  end

  defp enabled_user_ids, do: from(u in User, where: is_nil(u.disabled_at), select: u.id)

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

  @doc false
  # Also taken by Kanban.Organizations.MemberRemoval, so removing a member
  # serializes with every other membership write to the Organization, and by
  # Kanban.Accounts.AccountDeletion before it locks the user row, so every
  # path that takes both locks takes the Organization's first.
  @spec lock_organization(integer()) :: :ok | {:error, :not_found}
  def lock_organization(organization_id) do
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
  # the database cascade, and a locking read waits for that delete and then
  # skips the row, where a count would still see it. Only enabled org-admins
  # count as remaining; disabled members still count as members left behind.
  defp ensure_not_last_org_admin(%OrganizationMember{} = membership) do
    others =
      from(m in OrganizationMember,
        where: m.organization_id == ^membership.organization_id and m.id != ^membership.id
      )

    other_org_admins =
      others
      |> where([m], m.role == ^:org_admin and m.user_id in subquery(enabled_user_ids()))
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
