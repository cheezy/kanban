defmodule Kanban.Repo.Migrations.AddStateToScimUserLinks do
  use Ecto.Migration

  # deprovisioned_at: when SCIM itself ended the user's membership. Only such
  # a user stays reachable through the link once they are no longer a
  # member, so a person the Organization removed some other way drops out of
  # its SCIM view. given_name and family_name keep the name parts the
  # identity provider sent, so they read back as sent. scim_disabled_at is
  # the disabled_at SCIM's own deprovisioning set on an account the
  # Organization manages: SCIM re-enables the account only while it still
  # matches, so it never reverses a site admin's disable.
  def change do
    alter table(:scim_user_links) do
      add :deprovisioned_at, :utc_datetime
      add :given_name, :string
      add :family_name, :string
      add :scim_disabled_at, :utc_datetime
    end
  end
end
