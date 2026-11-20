defmodule Kanban.Devices.SsoExemption do
  @moduledoc """
  The web gate's single sign-on exemption from an Organization's two-factor
  requirement, carried to a device
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §8, decided 2026-11-19).

  On the web, a session signed in through single sign-on holds the id of the
  Organization whose identity provider signed it in, and
  `KanbanWeb.UserAuth.OrganizationTwoFactorGate.evaluate/2` exempts it from
  that Organization's two-factor requirement only while the id names the
  member's current Organization, re-read on every request.

  A device gets the same rule, in two steps:

    * **At Allow** (`POST /oauth/authorize`), `authorized_organization_id/2`
      reads the web session's mark against the scope's membership, exactly
      as the gate does, and the authorization code records the Organization
      id when the gate would exempt that session, and `nil` otherwise. The
      code exchange copies it onto the device (`sso_organization_id`).
    * **At every refresh**, `two_factor_refused?/3` refuses a member who is
      overdue on their Organization's requirement, unless the device's
      `sso_organization_id` names the member's current Organization, read
      again now. A member who has since moved to another Organization is
      held to that Organization's requirement, as the web session is.

  A device signed in from a password session has no mark and keeps the
  plain rule: refused once the grace period is over.
  """

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Organizations
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Organizations.SecurityPolicies

  @doc """
  The Organization id a sign-in allowed from a web session records: the
  session's single sign-on mark when it names the scope's own
  Organization, so the web gate would exempt the session, and `nil` for any
  other mark, no mark, or a scope without a membership.

      iex> scope = %Kanban.Accounts.Scope{
      ...>   organization_membership: %Kanban.Organizations.OrganizationMember{organization_id: 7}
      ...> }
      iex> Kanban.Devices.SsoExemption.authorized_organization_id(scope, 7)
      7
      iex> Kanban.Devices.SsoExemption.authorized_organization_id(scope, 8)
      nil
  """
  @spec authorized_organization_id(Scope.t() | nil, term()) :: pos_integer() | nil
  def authorized_organization_id(
        %Scope{organization_membership: %OrganizationMember{organization_id: organization_id}},
        organization_id
      )
      when is_integer(organization_id),
      do: organization_id

  def authorized_organization_id(_scope, _sso_mark), do: nil

  @doc """
  Whether a refresh for `user`, on a device whose single sign-on mark is
  `sso_organization_id`, is refused at `now` by the two-factor requirement:
  true when the user is overdue on their Organization's requirement and the
  mark does not name that Organization.
  """
  @spec two_factor_refused?(User.t(), pos_integer() | nil, DateTime.t()) :: boolean()
  def two_factor_refused?(%User{} = user, sso_organization_id, now) do
    case Organizations.get_membership(user) do
      %OrganizationMember{organization_id: ^sso_organization_id} ->
        false

      membership ->
        match?({:overdue, _deadline}, SecurityPolicies.two_factor_status(user, membership, now))
    end
  end
end
