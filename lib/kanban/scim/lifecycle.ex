defmodule Kanban.SCIM.Lifecycle do
  @moduledoc """
  Deprovisioning and re-activation of a SCIM user (W2247).

  Deactivating (`active: false` by PATCH or PUT) and deleting both end the
  user's place in the token's Organization through
  `Kanban.Accounts.deprovision_from_organization/2`, in one transaction with
  the user's `Kanban.SCIM.UserLink`: a deactivated user's link is marked
  deprovisioned, so the same Organization can still read and re-activate
  them, and a deleted user's link is detached, so they are no longer found.
  When the deprovisioning disables a managed account, the link records the
  `disabled_at` it set, so only SCIM's own disable is ever reversed by SCIM.
  Once committed, open board pages are told to re-read the user's access and
  the change is audited with the token's id.

  The caller disconnects the returned session tokens: those of a disabled
  account were deleted and are revoked for good
  (`KanbanWeb.UserAuth.disconnect_sessions/1`); the others are still valid
  and only their open pages are reconnected so they re-check their access
  (`KanbanWeb.UserAuth.disconnect_live_sessions/1`).
  """

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.AuditLog
  alias Kanban.Repo
  alias Kanban.SCIM.ScimToken
  alias Kanban.SCIM.UserLink
  alias Kanban.SSO
  alias Kanban.SSO.DomainVerification
  alias Kanban.Workspaces.MembershipCascade

  @type sessions :: {:revoked | :live, [Kanban.Accounts.UserToken.t()]}

  @doc """
  Deprovisions `user` from the token's Organization. `reason` is
  `:deactivated` (the link is kept and marks the user deprovisioned) or
  `:deleted` (the link is detached: it no longer makes the user reachable
  and forgets the `externalId` and name parts, but is kept so a later POST
  can re-enable an account SCIM disabled).
  Returns `{:ok, sessions}` or `{:error, :last_org_admin | :not_found}`.
  """
  @spec deprovision(ScimToken.t(), User.t(), :deactivated | :deleted) ::
          {:ok, sessions()} | {:error, :last_org_admin | :not_found}
  def deprovision(%ScimToken{organization_id: organization_id} = token, %User{} = user, reason)
      when reason in [:deactivated, :deleted] do
    fn -> deprovision_and_mark(organization_id, user, reason) end
    |> Repo.transact()
    |> report(token, user, reason)
  end

  defp deprovision_and_mark(organization_id, user, reason) do
    with {:ok, result} <- Accounts.deprovision_from_organization(user, organization_id) do
      {:ok, _link} = UserLink.upsert(organization_id, user.id, :keep)
      :ok = record_disable(organization_id, user.id, result.disabled_at)
      :ok = update_link(organization_id, user.id, reason)
      {:ok, result}
    end
  end

  defp record_disable(_organization_id, _user_id, nil), do: :ok

  defp record_disable(organization_id, user_id, disabled_at),
    do: UserLink.put_scim_disabled(organization_id, user_id, disabled_at)

  defp update_link(organization_id, user_id, :deactivated),
    do: UserLink.put_deprovisioned(organization_id, user_id, DateTime.utc_now(:second))

  defp update_link(organization_id, user_id, :deleted),
    do: UserLink.detach(organization_id, user_id)

  defp report({:ok, result}, token, user, reason) do
    MembershipCascade.broadcast_removed(result.removed)
    MembershipCascade.notify_derived_access_ended(user.id, token.organization_id)

    AuditLog.event(:scim_user_deprovisioned,
      organization_id: token.organization_id,
      scim_token_id: token.id,
      member_user_id: user.id,
      reason: reason,
      disabled: result.disabled,
      api_credentials_revoked: result.api_tokens_revoked
    )

    {:ok, {if(result.disabled, do: :revoked, else: :live), result.session_tokens}}
  end

  defp report({:error, _reason} = error, _token, _user, _reason_name), do: error

  @doc """
  Re-activates `user` in the token's Organization: restores a `:member`
  membership and re-enables an account the Organization manages, without
  restoring revoked tokens.

  An account the Organization does not manage is re-linked only while its
  email is on one of the Organization's verified domains, the same gate as
  provisioning (`Kanban.SSO.Provisioning.provision_scim/2`), so a token cannot
  pull back someone whose address it could not provision.

  Returns `{:ok, user}` or `{:error, :domain_not_verified | :user_disabled |
  :membership_conflict | :not_found}`.
  """
  @spec reactivate(ScimToken.t(), User.t()) ::
          {:ok, User.t()}
          | {:error, :domain_not_verified | :user_disabled | :membership_conflict | :not_found}
  def reactivate(%ScimToken{organization_id: organization_id} = token, %User{} = user) do
    with :ok <- check_domain(user, organization_id),
         {:ok, %{user: user}} <- Accounts.reactivate_in_organization(user, organization_id) do
      relink_reactivated(token, user)
    end
  end

  defp relink_reactivated(%ScimToken{organization_id: organization_id} = token, user) do
    {:ok, _link} = UserLink.upsert(organization_id, user.id, :keep)
    :ok = UserLink.put_deprovisioned(organization_id, user.id, nil)

    AuditLog.event(:scim_user_provisioned,
      organization_id: organization_id,
      scim_token_id: token.id,
      member_user_id: user.id,
      outcome: :reactivated
    )

    {:ok, user}
  end

  defp check_domain(%User{managed_by_organization_id: organization_id}, organization_id),
    do: :ok

  defp check_domain(%User{email: email}, organization_id) do
    with {:ok, domain} <- DomainVerification.email_domain(email),
         true <- SSO.domain_verified_by?(organization_id, domain) do
      :ok
    else
      _not_verified -> {:error, :domain_not_verified}
    end
  end
end
