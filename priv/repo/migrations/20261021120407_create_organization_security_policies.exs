defmodule Kanban.Repo.Migrations.CreateOrganizationSecurityPolicies do
  use Ecto.Migration

  # One security policy per Organization (W2244). No row means the defaults:
  # two-factor not required and audit events kept forever. Grace deadlines are
  # computed from two_factor_enforced_at and each membership's inserted_at, so
  # there is no per-member column and nothing to backfill.
  def change do
    create table(:organization_security_policies) do
      add :organization_id, references(:organizations, on_delete: :restrict), null: false
      add :require_two_factor, :boolean, null: false, default: false
      add :two_factor_grace_days, :integer, null: false, default: 7
      add :two_factor_enforced_at, :utc_datetime
      add :audit_retention_days, :integer
      add :updated_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:organization_security_policies, [:organization_id])
    create index(:organization_security_policies, [:updated_by_id])

    create constraint(:organization_security_policies, :two_factor_grace_days_range,
             check: "two_factor_grace_days BETWEEN 1 AND 30"
           )

    create constraint(:organization_security_policies, :audit_retention_days_range,
             check: "audit_retention_days IS NULL OR audit_retention_days BETWEEN 90 AND 3650"
           )

    create constraint(:organization_security_policies, :two_factor_enforced_at_when_required,
             check: "NOT require_two_factor OR two_factor_enforced_at IS NOT NULL"
           )
  end
end
