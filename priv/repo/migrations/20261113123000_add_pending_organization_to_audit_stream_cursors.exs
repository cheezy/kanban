defmodule Kanban.Repo.Migrations.AddPendingOrganizationToAuditStreamCursors do
  @moduledoc """
  The Organization a pending audit stream batch was cut for (D428, design
  §8.3).

  Every event of a batch carries the Organization's id and name. They are
  stored on the cursor with the other `pending_` fields when a batch is cut,
  and every retry of that `batch_id` builds its events from them, so a rename
  between attempts never changes the Organization a batch names. Both columns
  are NULL for a batch cut before this migration, whose next attempt stores
  them from the live row, and every path that discards a pending batch clears
  them.
  """

  use Ecto.Migration

  def change do
    alter table(:audit_stream_cursors) do
      add :pending_organization_id, :bigint
      add :pending_organization_name, :string
    end
  end
end
