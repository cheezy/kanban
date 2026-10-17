defmodule Kanban.Repo.Migrations.CreateOrganizations do
  @moduledoc """
  Paying Organizations and their members (W2390).

  `organizations` holds an Organization's name, postal address and contact.
  There is no plan, paid or seat column: whether an Organization pays is
  derived from the workspaces that point at it.

  `organization_members` links a user to one Organization. The unique index on
  `user_id` means a user belongs to at most one Organization. `role` is
  `org_admin` or `member`, and the check constraint enforces that in the
  database as well as in `Kanban.Organizations.OrganizationMember`. An
  Organization that still has members cannot be deleted (`on_delete:
  :restrict`); deleting a user removes their membership.
  """

  use Ecto.Migration

  def change do
    create table(:organizations) do
      add :name, :string, null: false
      add :address_line1, :string
      add :address_line2, :string
      add :city, :string
      add :region, :string
      add :postal_code, :string
      add :country, :string
      add :contact_name, :string, null: false
      add :contact_phone, :string
      add :contact_email, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create table(:organization_members) do
      add :organization_id, references(:organizations, on_delete: :restrict), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :role, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:organization_members, [:user_id])
    create index(:organization_members, [:organization_id])

    create constraint(:organization_members, :organization_members_role_check,
             check: "role IN ('org_admin', 'member')"
           )
  end
end
