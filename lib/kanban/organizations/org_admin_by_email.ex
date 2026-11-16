defmodule Kanban.Organizations.OrgAdminByEmail do
  @moduledoc """
  Appoints an org-admin by email, for
  `Kanban.Organizations.appoint_org_admin_by_email/4`.

  The caller has already checked the actor: `Kanban.Organizations` refuses
  anyone but an enabled site admin, and validates `urls`, before it calls
  `appoint/4`. This module checks no actor itself, so nothing else should call
  it.

  An enabled account is appointed through
  `Kanban.Organizations.MembershipWrites.appoint_org_admin/4` and gets the
  `Kanban.Organizations.OrgAdminNotice` email; a disabled one is refused with
  `{:error, :user_disabled}`. An unknown email goes to
  `Kanban.Organizations.OrgAdminProvisioning`, and an email registered between
  the lookup and the insert is appointed rather than duplicated.
  """

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Organizations.MembershipWrites
  alias Kanban.Organizations.OrgAdminNotice
  alias Kanban.Organizations.OrgAdminProvisioning
  alias Kanban.Organizations.Organization
  alias Kanban.Organizations.OrganizationMember

  @doc """
  Appoints the account with `email` as an org-admin of `organization`,
  creating it when no account has that email.

  `email` is already trimmed, `urls` already validated and `actor` already
  checked, by `Kanban.Organizations.appoint_org_admin_by_email/4`.
  """
  @spec appoint(User.t(), Organization.t() | integer(), String.t(), OrgAdminProvisioning.urls()) ::
          {:ok, OrganizationMember.t()}
          | {:error,
             :user_disabled
             | :already_in_another_organization
             | :not_found
             | Ecto.Changeset.t()}
  def appoint(actor, organization, email, urls) do
    case Accounts.get_user_by_email(email) do
      %User{} = user ->
        appoint_existing_account(actor, organization, user)

      nil ->
        actor
        |> OrgAdminProvisioning.provision(organization_id(organization), email, urls)
        |> appoint_if_registered_meanwhile(actor, organization, email)
    end
  end

  defp appoint_existing_account(_actor, _organization, %User{disabled_at: %DateTime{}}),
    do: {:error, :user_disabled}

  # The actor was checked by Kanban.Organizations.appoint_org_admin_by_email/4.
  defp appoint_existing_account(actor, organization, %User{} = user) do
    MembershipWrites.appoint_org_admin(actor, organization_id(organization), user,
      on_appointed: &OrgAdminNotice.deliver(user, &1)
    )
  end

  # Another write registered the email between the lookup and the insert, so
  # that account is appointed instead of creating a second one.
  defp appoint_if_registered_meanwhile({:error, :email_taken}, actor, organization, email) do
    case Accounts.get_user_by_email(email) do
      %User{} = user -> appoint_existing_account(actor, organization, user)
      nil -> {:error, :not_found}
    end
  end

  defp appoint_if_registered_meanwhile(result, _actor, _organization, _email), do: result

  defp organization_id(%Organization{id: id}), do: id
  defp organization_id(id) when is_integer(id), do: id
end
