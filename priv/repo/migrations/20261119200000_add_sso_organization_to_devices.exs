defmodule Kanban.Repo.Migrations.AddSsoOrganizationToDevices do
  @moduledoc """
  Records, on a device and on the authorization code that signs it in, the
  Organization whose single sign-on signed in the web session that allowed
  the sign-in (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §8).

  `sso_organization_id` is the device's copy of the web session's single
  sign-on mark (`KanbanWeb.UserAuth.OrganizationTwoFactorGate`), taken when
  the person pressed Allow on `/oauth/authorize` and only when the web gate
  would have exempted that session. It is `nil` for a password sign-in. A
  refresh is exempt from the Organization's two-factor requirement only while
  it still names the member's current Organization, as the web session's mark
  is. The mark is a fact about the sign-in, so deleting the Organization
  clears it rather than deleting the device.
  """
  use Ecto.Migration

  def change do
    alter table(:oauth_authorization_codes) do
      add :sso_organization_id, references(:organizations, on_delete: :nilify_all)
    end

    alter table(:user_devices) do
      add :sso_organization_id, references(:organizations, on_delete: :nilify_all)
    end

    create index(:oauth_authorization_codes, [:sso_organization_id])
    create index(:user_devices, [:sso_organization_id])
  end
end
