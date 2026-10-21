defmodule Kanban.Repo.Migrations.CreateScimTables do
  use Ecto.Migration

  def change do
    create table(:scim_tokens) do
      add :organization_id, references(:organizations, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :token_hash, :string, null: false
      add :last_used_at, :utc_datetime
      add :revoked_at, :utc_datetime
      add :created_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:scim_tokens, [:token_hash])
    create index(:scim_tokens, [:organization_id])
    create index(:scim_tokens, [:created_by_id])

    alter table(:users) do
      add :managed_by_organization_id, references(:organizations, on_delete: :nilify_all)
    end

    create index(:users, [:managed_by_organization_id])

    # Which users an Organization's identity provider has provisioned or
    # linked, so a deprovisioned user stays reachable for re-activation and
    # their externalId round-trips. It grants no access.
    create table(:scim_user_links) do
      add :organization_id, references(:organizations, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :external_id, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:scim_user_links, [:organization_id, :user_id])
    create index(:scim_user_links, [:user_id])
  end
end
