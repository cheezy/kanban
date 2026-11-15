defmodule Kanban.Repo.Migrations.UniqueAuditStreamDestinationNamesIgnoringCase do
  @moduledoc """
  Makes audit stream destination names unique within an Organization ignoring
  case (D445).

  The first index, `audit_stream_destinations_organization_id_name_index`, was
  on the raw name, so "Splunk" and "splunk" could both exist and look like the
  same destination on the list page, in the status emails and in the audit
  log. It is replaced by `audit_stream_destinations_organization_id_lower_name_index`
  on `(organization_id, lower(name))`, which `Kanban.AuditStream.Destination`
  maps to a `:name` error.

  Rows that already break the rule are renamed first, so the index always
  builds:

    * In each group of names in one Organization that match ignoring case, the
      oldest destination (by `inserted_at`, then `id`) keeps its name.
    * Each later one, oldest first, gets the first free numeric suffix from
      " (2)" upwards: "Splunk (2)", "Splunk (3)". A suffix is free when no
      destination in that Organization already has that name, ignoring case,
      so an existing "Splunk (2)" pushes the next duplicate to "Splunk (3)".
    * A renamed name is cut so the result stays within the 80 characters the
      column and the changeset allow.
    * A renamed row's `lock_version` goes up, so an edit form loaded before the
      rename is refused as stale rather than saved over the new name.

  Names are never compared or renamed across Organizations. Only the count of
  renamed rows is logged, never a name, URL or credential.

  The rename is a PL/pgSQL loop rather than one set-based UPDATE because each
  free suffix depends on the renames made before it in the same run.
  Duplicates are rare, so going row by row costs nothing. `dedupe_statements/0`
  is public so `test/kanban/audit_stream/unique_name_migration_test.exs` runs
  exactly the statements `up/0` does. Running them twice changes nothing.

  The table lock stops app code that is still running during a deploy from
  inserting a new duplicate between the rename and the index build. It is held
  until the migration's transaction ends, so it also covers the index build.
  """

  use Ecto.Migration

  require Logger

  @old_index_name :audit_stream_destinations_organization_id_name_index
  @index_name :audit_stream_destinations_organization_id_lower_name_index

  def up do
    execute(&log_duplicates/0)
    Enum.each(dedupe_statements(), &execute/1)

    drop_if_exists index(:audit_stream_destinations, [:organization_id, :name],
                     name: @old_index_name
                   )

    create unique_index(:audit_stream_destinations, [:organization_id, "lower(name)"],
             name: @index_name
           )
  end

  # Renamed duplicates keep their new names: the old names were ambiguous, and
  # nothing records which row had which. The raw-name index is rebuilt, which
  # the renamed rows always satisfy.
  def down do
    drop_if_exists index(:audit_stream_destinations, [:organization_id, "lower(name)"],
                     name: @index_name
                   )

    create unique_index(:audit_stream_destinations, [:organization_id, :name],
             name: @old_index_name
           )
  end

  def dedupe_statements do
    [
      "LOCK TABLE audit_stream_destinations IN SHARE ROW EXCLUSIVE MODE",
      """
      DO $$
      DECLARE
        dup record;
        n integer;
        suffix text;
        candidate text;
      BEGIN
        FOR dup IN
          SELECT id, organization_id, name
          FROM (
            SELECT id, organization_id, name,
                   row_number() OVER (
                     PARTITION BY organization_id, lower(name)
                     ORDER BY inserted_at, id
                   ) AS rn
            FROM audit_stream_destinations
          ) ranked
          WHERE rn > 1
          ORDER BY organization_id, lower(name), rn
        LOOP
          n := 2;

          LOOP
            suffix := ' (' || n || ')';
            candidate := rtrim(left(dup.name, 80 - length(suffix))) || suffix;

            EXIT WHEN NOT EXISTS (
              SELECT 1 FROM audit_stream_destinations d
              WHERE d.organization_id = dup.organization_id
                AND lower(d.name) = lower(candidate)
            );

            n := n + 1;
          END LOOP;

          UPDATE audit_stream_destinations
          SET name = candidate,
              lock_version = lock_version + 1,
              updated_at = date_trunc('second', now() AT TIME ZONE 'UTC')
          WHERE id = dup.id;
        END LOOP;
      END
      $$
      """
    ]
  end

  defp log_duplicates do
    %{rows: [[renamed]]} =
      repo().query!("""
      SELECT count(*) FROM (
        SELECT row_number() OVER (
                 PARTITION BY organization_id, lower(name)
                 ORDER BY inserted_at, id
               ) AS rn
        FROM audit_stream_destinations
      ) ranked
      WHERE rn > 1
      """)

    Logger.info("Audit stream destination name dedupe: #{renamed} later duplicates renamed")
  end
end
