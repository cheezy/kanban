defmodule Kanban.Repo.Migrations.CreateOrganizationTwoFactorGrace do
  use Ecto.Migration

  # When each member's two-factor grace period started under their
  # Organization's current requirement (decided 2026-10-21: grace counts once
  # per user per Organization, kept across re-joins). enforced_at is the
  # policy's two_factor_enforced_at the row belongs to; a row for an older
  # enforcement is replaced, never read. Nothing to backfill: a missing row is
  # computed from the membership as before and written on first use.
  def change do
    create table(:organization_two_factor_grace) do
      add :organization_id, references(:organizations, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :enforced_at, :utc_datetime, null: false
      add :started_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:organization_two_factor_grace, [:organization_id, :user_id])
    create index(:organization_two_factor_grace, [:user_id])
  end
end
