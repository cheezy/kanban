defmodule Kanban.Repo.Migrations.AddHideTitlesInNotificationsToOrganizationSecurityPolicies do
  use Ecto.Migration

  # Lock-screen privacy (W2769): when on, push notifications to the
  # Organization's members leave out task titles. Existing policies, and
  # Organizations with no policy row, keep showing titles, so nothing changes
  # until an org-admin turns it on and there is nothing to backfill.
  def change do
    alter table(:organization_security_policies) do
      add :hide_titles_in_notifications, :boolean, null: false, default: false
    end
  end
end
