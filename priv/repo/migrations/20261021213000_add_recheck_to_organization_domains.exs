defmodule Kanban.Repo.Migrations.AddRecheckToOrganizationDomains do
  use Ecto.Migration

  # The daily re-check of verified domains (decided 2026-10-21,
  # Kanban.SSO.DomainRecheckWorker). failed_checks counts consecutive daily
  # checks that did not find the TXT record and failing_since is when the
  # first of them ran; both are reset by a check that finds it. A domain
  # stops being verified after three misses in a row.
  def change do
    alter table(:organization_domains) do
      add :last_checked_at, :utc_datetime
      add :failed_checks, :integer, null: false, default: 0
      add :failing_since, :utc_datetime
    end

    create constraint(:organization_domains, :failed_checks_not_negative,
             check: "failed_checks >= 0"
           )
  end
end
