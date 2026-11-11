defmodule Kanban.Organizations.OrgAdminNotice do
  @moduledoc """
  Emails the holder of an existing account when a site admin appoints them
  org-admin by email, for `Kanban.Organizations.appoint_org_admin_by_email/4`.

  An account created by the appointment is emailed by
  `Kanban.Organizations.OrgAdminProvisioning` instead. Both emails carry the
  Resources guides for setting the Organization up
  (`Kanban.Accounts.UserNotifier`).
  """

  import Ecto.Query, only: [from: 2]

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Organizations.Organization
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo

  @doc """
  Sends `user` the you-are-now-an-org-admin email for the Organization of
  `membership`. Call it only once the appointment has committed.
  """
  @spec deliver(User.t(), OrganizationMember.t()) :: {:ok, Swoosh.Email.t()}
  def deliver(%User{} = user, %OrganizationMember{organization_id: organization_id}) do
    name =
      from(o in Organization, where: o.id == ^organization_id, select: o.name)
      |> Repo.one!()

    Accounts.deliver_org_admin_appointed_notice(user, name)
  end
end
