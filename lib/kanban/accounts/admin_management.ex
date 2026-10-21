defmodule Kanban.Accounts.AdminManagement do
  @moduledoc """
  Admin-facing user management: listing, disabling/enabling, and deletion.

  Exposed through the `Kanban.Accounts` facade via `defdelegate` — call these
  as `Accounts.list_users/0`, `Accounts.disable_user/1`, and so on rather than
  reaching into this module directly.

  A disable, enable or delete that changes something emits
  `[:kanban, :user, :disabled]`, `:enabled` or `:deleted` through
  `Kanban.Accounts.UserTelemetry`, with the administrator as `actor_user_id`.
  Every deletion attempt, successful or refused, is also recorded in
  `Kanban.AuditLog` as `:user_deleted` or `:user_delete_refused`.

  Disabling or deleting the last enabled org-admin of an Organization that has
  other members is refused with `:last_org_admin`, so no Organization is left
  without someone who can run it. The check
  (`Kanban.Organizations.ensure_not_last_working_org_admin/1`) runs in the
  same transaction as the write, under the Organization's row lock.

  Disabling a user does not close their open pages by itself: the caller
  disconnects them with `KanbanWeb.UserAuth.disconnect_live_sessions/1` and
  `Kanban.Accounts.list_session_tokens/1`.

  SCIM provisioning (W2247) ends and restores an account's place in an
  Organization with `deprovision_from_organization/2` and
  `reactivate_in_organization/2`. They take no administrator: the identity
  provider's token was already checked, and the SCIM layer records the audit
  event with the token's id.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Accounts.UserTelemetry
  alias Kanban.Accounts.UserToken
  alias Kanban.ApiTokens
  alias Kanban.Boards
  alias Kanban.Organizations
  alias Kanban.Organizations.MembershipWrites
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias Kanban.SCIM.UserLink
  alias Kanban.Telemetry.AfterCommit
  alias Kanban.Webhooks
  alias Kanban.Workspaces
  alias Kanban.Workspaces.InvitationRevocation
  alias Kanban.Workspaces.MembershipCascade

  @doc """
  Returns every user, ordered by email.

  Disabled users are included — the admin list needs to show them in order to
  enable them again.

  ## Examples

      iex> list_users()
      [%User{}, ...]

  """
  def list_users do
    User
    |> order_by([u], asc: u.email)
    |> Repo.all()
  end

  @doc """
  Disables a user by setting `disabled_at` to the current UTC time.

  `current_user` is the admin performing the action, passed last to match
  `delete_user/2` and `Kanban.Boards.remove_user_from_board/3`.

  Disabling an already-disabled user is allowed and refreshes the timestamp.

  Changes nothing and returns `{:error, reason}` when:

    * `:unauthorized` - the acting user is not an enabled admin
    * `:cannot_disable_self` - the target is the acting user, which is the way
      a lone admin would lock everyone out
    * `:last_admin` - the target is the last admin
    * `:last_org_admin` - the target is the last enabled org-admin of an
      Organization that has other members

  ## Examples

      iex> disable_user(user, admin)
      {:ok, %User{}}

      iex> disable_user(admin, admin)
      {:error, :cannot_disable_self}

  """
  def disable_user(%User{} = user, %User{} = current_user) do
    cond do
      not authorized_admin?(current_user) -> {:error, :unauthorized}
      user.id == current_user.id -> {:error, :cannot_disable_self}
      last_admin?(user) -> {:error, :last_admin}
      true -> user |> do_disable() |> UserTelemetry.disabled(user, current_user)
    end
  end

  defp do_disable(user) do
    Repo.transact(fn ->
      with :ok <- Organizations.ensure_not_last_working_org_admin(user),
           {:ok, user} <-
             user |> User.disabled_changeset(DateTime.utc_now(:second)) |> Repo.update() do
        forget_scim_disable(user)
      end
    end)
  end

  # A site admin's disable or enable supersedes SCIM's, so SCIM never
  # re-enables an account a site admin acted on, even in the same second.
  defp forget_scim_disable(user) do
    :ok = UserLink.clear_scim_disabled_for_user(user.id)
    {:ok, user}
  end

  @doc """
  Enables a user by clearing `disabled_at`.

  `current_user` is the admin performing the action, passed last to match
  `disable_user/2` and `delete_user/2`. Re-enabling an account is a privilege
  grant (it undoes an admin lockout), so it is gated on the same enabled-admin
  check as its siblings. Unlike disable/delete there is no self-target or
  last-admin guard — enabling is not destructive.

  Returns `{:error, :unauthorized}` when the acting user is not an enabled admin.

  ## Examples

      iex> enable_user(user, admin)
      {:ok, %User{}}

      iex> enable_user(user, non_admin)
      {:error, :unauthorized}

  """
  def enable_user(%User{} = user, %User{} = current_user) do
    if authorized_admin?(current_user) do
      user |> do_enable() |> UserTelemetry.enabled(user, current_user)
    else
      {:error, :unauthorized}
    end
  end

  defp do_enable(user) do
    Repo.transact(fn ->
      with {:ok, user} <- user |> User.disabled_changeset(nil) |> Repo.update() do
        forget_scim_disable(user)
      end
    end)
  end

  @doc """
  Deletes a user along with their session and email tokens and their personal
  workspace, all in one transaction.

  `current_user` is the admin performing the deletion, passed last to match
  `Kanban.Boards.remove_user_from_board/3`.

  Deletes nothing and returns `{:error, reason}` when:

    * `:unauthorized` - the acting user is not an enabled admin
    * `:cannot_delete_self` - the target is the acting user
    * `:user_has_boards` - the target belongs to at least one board
    * `:last_admin` - the target is the last admin
    * `:last_org_admin` - the target is the last enabled org-admin of an
      Organization that has other members
    * `:personal_workspace_has_boards` - a board still sits in the target's
      personal workspace, even one they are not a member of. The foreign key
      refuses it inside the transaction, so a board placed there at the same
      moment is refused too and the whole delete rolls back

  A successful deletion records a `:user_deleted` audit event and every
  refusal above records a `:user_delete_refused` audit event naming its
  reason, both with `current_user` as the actor. They are written after the
  deletion's transaction has returned, so call this outside any enclosing
  transaction: rolling that one back would erase the record of the attempt.

  ## Examples

      iex> delete_user(user, admin)
      {:ok, %User{}}

      iex> delete_user(admin, admin)
      {:error, :cannot_delete_self}

  """
  def delete_user(%User{} = user, %User{} = current_user) do
    user
    |> attempt_delete(current_user)
    |> UserTelemetry.deleted(user, current_user)
  end

  defp attempt_delete(user, current_user) do
    cond do
      not authorized_admin?(current_user) -> {:error, :unauthorized}
      user.id == current_user.id -> {:error, :cannot_delete_self}
      Boards.user_has_boards?(user) -> {:error, :user_has_boards}
      last_admin?(user) -> {:error, :last_admin}
      true -> delete_user_and_tokens(user)
    end
  end

  # Rejects a disabled admin whose scope was re-fetched after the disable landed,
  # which covers any new request or mount. This reads the struct in memory, so an
  # actor loaded before the disable still passes — `last_admin?/1` is the
  # DB-authoritative check for that case. Closing the window entirely means
  # rejecting disabled users' sessions at the auth layer.
  defp authorized_admin?(%User{disabled_at: nil} = user), do: Accounts.admin?(user)
  defp authorized_admin?(%User{}), do: false

  # The personal workspace goes before the user row: its owner row is deleted
  # with the user, after which the workspace could no longer be found. The
  # webhook endpoints they created stop sending to a URL they chose.
  defp delete_user_and_tokens(user) do
    Repo.transact(fn ->
      with :ok <- Organizations.ensure_not_last_working_org_admin(user),
           {_count, _} <- Repo.delete_all(UserToken.by_user_and_contexts_query(user, :all)),
           _paused <- Webhooks.pause_creator_endpoints(user.id, :all),
           {:ok, _workspace} <- Workspaces.delete_personal_workspace(user) do
        Repo.delete(user)
      end
    end)
  end

  @typedoc "What `deprovision_from_organization/2` changed, for the caller to report."
  @type deprovision_result :: %{
          membership: OrganizationMember.t() | nil,
          removed: MembershipCascade.removed(),
          disabled: boolean(),
          disabled_at: DateTime.t() | nil,
          session_tokens: [UserToken.t()],
          api_tokens_revoked: non_neg_integer()
        }

  @doc """
  Ends `user`'s place in the Organization with `organization_id`, as SCIM
  deprovisioning does (W2247), in one transaction.

  In every workspace of the Organization, archived ones included, the user's
  board memberships are deleted, their board and workspace API tokens there
  revoked, their open tasks unassigned and their workspace memberships
  deleted (`Kanban.Workspaces.MembershipCascade.remove_from_organization/2`);
  open invitations addressed to them, or sent by them, in those workspaces
  are revoked; and their Organization membership is deleted. Boards outside
  the Organization are left alone.

  When the account is managed by this Organization (SCIM created it) it is
  also disabled, every session and email token of it deleted and every API
  token of it revoked (`Kanban.ApiTokens.revoke_all_user_tokens/1`). A site
  admin, or an account the Organization does not manage, is never disabled.

  Refuses with `{:error, :last_org_admin}`, changing nothing, when the user
  is the last enabled org-admin of an Organization that has other members,
  and with `{:error, :not_found}` when the Organization or the user does not
  exist, or when the user, re-checked under the lock, is no longer the
  Organization's: no membership of it, and either a membership elsewhere or
  no deprovisioned mark on its SCIM link. Running it again on a user SCIM
  deprovisioned changes nothing more.

  Emits nothing. After commit the caller disconnects `session_tokens`: the
  deleted session tokens of a disabled account, or the still-valid ones of
  any other account, whose pages re-check their access on reconnect.
  """
  @spec deprovision_from_organization(User.t(), integer()) ::
          {:ok, deprovision_result()} | {:error, :last_org_admin | :not_found}
  def deprovision_from_organization(%User{id: user_id}, organization_id)
      when is_integer(organization_id) do
    invitations = [
      InvitationRevocation.addressed_to(user_id, {:organization, organization_id}),
      InvitationRevocation.sent_by(user_id, organization_id)
    ]

    Repo.transact(fn -> deprovision_locked(user_id, organization_id, invitations) end)
  end

  defp deprovision_locked(user_id, organization_id, invitations) do
    with :ok <- InvitationRevocation.lock(invitations),
         :ok <- MembershipWrites.lock_organization(organization_id),
         {:ok, user} <- lock_user(user_id),
         {:ok, membership, removed} <- leave_organization(user, organization_id, invitations) do
      {:ok, disable_if_managed(user, organization_id, membership, removed)}
    end
  end

  defp leave_organization(user, organization_id, invitations) do
    case lock_membership(organization_id, user.id) do
      nil ->
        if deprovisioned_from?(user, organization_id),
          do: {:ok, nil, []},
          else: {:error, :not_found}

      membership ->
        with :ok <- Organizations.ensure_not_last_working_org_admin(user) do
          removed = MembershipCascade.remove_from_organization(user.id, organization_id)
          InvitationRevocation.revoke(invitations)
          {:ok, deleted} = Repo.delete(membership)
          {:ok, deleted, removed}
        end
    end
  end

  defp disable_if_managed(user, organization_id, membership, removed) do
    result = %{
      membership: membership,
      removed: removed,
      disabled: false,
      disabled_at: nil,
      session_tokens: [],
      api_tokens_revoked: 0
    }

    if managed_by?(user, organization_id) do
      disable_managed(user, result)
    else
      %{result | session_tokens: Accounts.list_session_tokens(user)}
    end
  end

  defp disable_managed(user, result) do
    tokens = user |> UserToken.by_user_and_contexts_query(:all) |> Repo.all()
    user |> UserToken.by_user_and_contexts_query(:all) |> Repo.delete_all()
    {revoked, _} = ApiTokens.revoke_all_user_tokens(user.id)

    # disabled_at is set only when this deprovisioning disabled the account,
    # so a caller can tell its own disable from an earlier one.
    disabled_at =
      if is_nil(user.disabled_at) do
        now = DateTime.utc_now(:second)
        {:ok, _user} = user |> User.disabled_changeset(now) |> Repo.update()
        now
      end

    %{
      result
      | disabled: true,
        disabled_at: disabled_at,
        session_tokens: Enum.filter(tokens, &(&1.context == "session")),
        api_tokens_revoked: revoked
    }
  end

  @doc """
  Restores `user`'s place in the Organization with `organization_id` when SCIM
  re-activates them (W2247): an account managed by this Organization is
  enabled again, and the user gets a `:member` membership (an org-admin keeps
  their role). Revoked tokens stay revoked and deleted sessions stay deleted.

  Returns `{:ok, %{user: user, enabled: enabled}}`, or changes nothing and
  returns `{:error, reason}`:

    * `:user_disabled` - the account is disabled and this Organization does
      not manage it, or it is a site admin
    * `:membership_conflict` - the user has joined another Organization
    * `:not_found` - the Organization or the user does not exist

  Membership telemetry is emitted once the transaction has committed.
  """
  @spec reactivate_in_organization(User.t(), integer()) ::
          {:ok, %{user: User.t(), enabled: boolean()}}
          | {:error, :user_disabled | :membership_conflict | :not_found}
  def reactivate_in_organization(%User{id: user_id}, organization_id)
      when is_integer(organization_id) do
    AfterCommit.after_commit(fn ->
      Repo.transact(fn -> reactivate_locked(user_id, organization_id) end)
    end)
  end

  defp reactivate_locked(user_id, organization_id) do
    with :ok <- MembershipWrites.lock_organization(organization_id),
         {:ok, user} <- lock_user(user_id),
         {:ok, user, enabled} <- enable_if_managed(user, organization_id),
         {:ok, _membership} <- rejoin_organization(user, organization_id) do
      {:ok, %{user: user, enabled: enabled}}
    end
  end

  defp enable_if_managed(%User{disabled_at: nil} = user, _organization_id),
    do: {:ok, user, false}

  # A managed account is enabled again only when SCIM's own deprovisioning
  # disabled it: its link still records the account's disabled_at. An
  # account a site admin disabled stays disabled.
  defp enable_if_managed(user, organization_id) do
    if managed_by?(user, organization_id) and disabled_by_scim?(user, organization_id) do
      {:ok, user} = user |> User.disabled_changeset(nil) |> Repo.update()
      {:ok, user, true}
    else
      {:error, :user_disabled}
    end
  end

  defp rejoin_organization(user, organization_id) do
    case Organizations.add_member(organization_id, user, :member) do
      {:ok, membership} -> {:ok, membership}
      {:error, :already_in_another_organization} -> {:error, :membership_conflict}
      {:error, :user_disabled} -> {:error, :user_disabled}
      {:error, _other} -> {:error, :not_found}
    end
  end

  defp disabled_by_scim?(%User{id: user_id, disabled_at: disabled_at}, organization_id) do
    case UserLink.get(organization_id, user_id) do
      %UserLink{scim_disabled_at: %DateTime{} = at} -> DateTime.compare(at, disabled_at) == :eq
      _other -> false
    end
  end

  # Only the Organization whose SCIM created the account manages it, and a
  # site admin is never managed.
  defp managed_by?(%User{type: :admin}, _organization_id), do: false

  defp managed_by?(%User{managed_by_organization_id: managed_by}, organization_id),
    do: managed_by == organization_id

  # The Organization row is locked first, then the user row: the order
  # Kanban.Accounts.AccountDeletion takes them in.
  defp lock_user(user_id) do
    from(u in User, where: u.id == ^user_id, lock: "FOR UPDATE")
    |> Repo.one()
    |> case do
      %User{} = user -> {:ok, user}
      nil -> {:error, :not_found}
    end
  end

  # Re-checked under the user lock, which joining an Organization also takes:
  # a user with no membership here is still this Organization's only while
  # SCIM's deprovisioning marked them and they have joined no Organization
  # since, so a concurrent join elsewhere is never disabled from here.
  defp deprovisioned_from?(%User{id: user_id}, organization_id) do
    memberships = from(m in OrganizationMember, where: m.user_id == ^user_id)
    member_anywhere = Repo.exists?(memberships)
    link = UserLink.get(organization_id, user_id)
    not member_anywhere and match?(%UserLink{deprovisioned_at: %DateTime{}}, link)
  end

  defp lock_membership(organization_id, user_id) do
    from(m in OrganizationMember,
      where: m.organization_id == ^organization_id and m.user_id == ^user_id,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  @doc """
  Returns true when `user` is a site admin and no other enabled site admin
  exists, read from the database. Disabling or deleting such a user would
  leave nobody who can sign in and administer the system.

  Only enabled admins count as "remaining": a disabled admin cannot log in to
  re-enable anyone. Any admin `user`, enabled or not, is checked, since
  deleting the only admin row leaves nobody to promote. A non-admin is never
  the last admin.

  Takes no lock; a caller that acts on the answer inside a transaction locks
  the admin rows first (see `Kanban.Accounts.AccountDeletion`).
  """
  @spec last_admin?(User.t()) :: boolean()
  def last_admin?(%User{type: :admin} = user) do
    User
    |> where([u], u.type == :admin and is_nil(u.disabled_at) and u.id != ^user.id)
    |> Repo.exists?()
    |> Kernel.not()
  end

  def last_admin?(_user), do: false
end
