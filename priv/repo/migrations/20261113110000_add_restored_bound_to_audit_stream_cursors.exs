defmodule Kanban.Repo.Migrations.AddRestoredBoundToAuditStreamCursors do
  @moduledoc """
  The rows a logical database move restored with the old server's
  transaction ids (D427, design §8.8).

  After a dump and restore, restored audit events keep their old `txid`,
  which sorts after every row the new server writes. The re-seed
  (`Kanban.AuditStream.Reseed`) records the restored rows a destination had
  not received as a gap and stores their bound here: every event with
  `id <= restored_max_event_id` and `txid >= restored_min_txid` is never read
  for that destination again. Both columns are NULL until a re-seed finds
  restored rows, and are set together.
  """

  use Ecto.Migration

  def change do
    alter table(:audit_stream_cursors) do
      add :restored_max_event_id, :bigint
      add :restored_min_txid, :bigint
    end

    create constraint(:audit_stream_cursors, :audit_stream_cursors_restored_bound_complete,
             check: "(restored_max_event_id IS NULL) = (restored_min_txid IS NULL)"
           )
  end
end
