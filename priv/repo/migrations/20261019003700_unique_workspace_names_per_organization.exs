defmodule Kanban.Repo.Migrations.UniqueWorkspaceNamesPerOrganization do
  @moduledoc """
  Makes workspace names unique within an Organization (W2420).

  Among an Organization's unarchived, non-personal workspaces no two may share a
  name, compared ignoring case. The partial unique index
  `workspaces_organization_id_lower_name_index` enforces it, and
  `Kanban.Workspaces.Workspace` maps it to a `:name` error. Archived and
  personal workspaces are outside the index, so archiving frees a name.

  Rows that already break the rule are renamed first, so the index always
  builds:

    * In each group of live names that match ignoring case, the oldest
      workspace (by `inserted_at`, then `id`) keeps its name.
    * Each later one, oldest first, gets the first free numeric suffix from
      " (2)" upwards: "Design (2)", "Design (3)". A suffix is free when no live
      workspace in that Organization already has that name, ignoring case, so
      an existing "Design (2)" pushes the next duplicate to "Design (3)".
    * A renamed name is cut so the result stays within the 100 characters the
      changeset allows.

  The rename is a PL/pgSQL loop rather than one set-based UPDATE because each
  free suffix depends on the renames made before it in the same run. Duplicates
  are rare, so going row by row costs nothing. `dedupe_statements/0` is public
  so `test/kanban/workspaces/unique_name_migration_test.exs` runs exactly the
  statements `up/0` does. Running them twice changes nothing.

  The table lock stops app code that is still running during a deploy from
  inserting a new duplicate between the rename and the index build. It is held
  only until the migration's transaction ends.
  """

  use Ecto.Migration

  require Logger

  @index_name :workspaces_organization_id_lower_name_index

  def up do
    execute(&log_duplicates/0)
    Enum.each(dedupe_statements(), &execute/1)

    create unique_index(:workspaces, [:organization_id, "lower(name)"],
             where: "personal = false AND archived_at IS NULL",
             name: @index_name
           )
  end

  # Renamed duplicates keep their new names: the old names were ambiguous, and
  # nothing records which row had which.
  def down do
    drop_if_exists index(:workspaces, [:organization_id, "lower(name)"], name: @index_name)
  end

  def dedupe_statements do
    [
      "LOCK TABLE workspaces IN SHARE ROW EXCLUSIVE MODE",
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
            FROM workspaces
            WHERE personal = false AND archived_at IS NULL
          ) ranked
          WHERE rn > 1
          ORDER BY organization_id, lower(name), rn
        LOOP
          n := 2;

          LOOP
            suffix := ' (' || n || ')';
            candidate := rtrim(left(dup.name, 100 - length(suffix))) || suffix;

            EXIT WHEN NOT EXISTS (
              SELECT 1 FROM workspaces w
              WHERE w.organization_id = dup.organization_id
                AND w.personal = false
                AND w.archived_at IS NULL
                AND lower(w.name) = lower(candidate)
            );

            n := n + 1;
          END LOOP;

          UPDATE workspaces
          SET name = candidate,
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
        FROM workspaces
        WHERE personal = false AND archived_at IS NULL
      ) ranked
      WHERE rn > 1
      """)

    Logger.info("Workspace name dedupe: #{renamed} later duplicates renamed")
  end
end
