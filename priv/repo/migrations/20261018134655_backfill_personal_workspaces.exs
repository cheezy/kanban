defmodule Kanban.Repo.Migrations.BackfillPersonalWorkspaces do
  @moduledoc """
  Grandfathers every existing user and board into hidden personal workspaces
  (W2217), so `boards.workspace_id` can become NOT NULL in the next migration.

  * Every user without one gets a personal workspace with a single owner row.
    Disabled users are included: the rule is one per user.
  * A board with an owner row moves into its owner's personal workspace.
  * A board with no owner row moves into the personal workspace of its earliest
    remaining member (by `board_users.inserted_at`, then `id`).
  * A board with no members at all moves into the personal workspace of the
    earliest enabled site admin (by `users.inserted_at`, then `id`). If such a
    board exists and no enabled site admin does, the migration raises.

  Placement grants nothing. A personal workspace takes no member or guest rows
  and gives no derived board access, so every user keeps exactly the access
  their unchanged `board_users` rows already give them, and boards above the
  free member cap keep every member. No `board_users` row is written or
  deleted.

  The work is set-based SQL only, never Elixir loops over schemas, so a later
  schema change cannot break this migration. `backfill_statements/0` is public
  so `test/kanban/workspaces/grandfather_migration_test.exs` runs exactly the
  statements `up/0` does. Running them twice changes nothing: users who already
  own a workspace and boards that already have one are skipped.
  """

  use Ecto.Migration

  require Logger

  def up do
    Enum.each(backfill_statements(), &execute/1)
    execute(&log_counts/0)
  end

  # One-way data backfill: once placed, grandfathered boards and workspaces are
  # indistinguishable from ones created after this release, so down is a no-op.
  def down, do: :ok

  @doc """
  The backfill, in order, as SQL statements.
  """
  def backfill_statements do
    [
      # pg_temp: never drop a permanent table that happens to share the name.
      "DROP TABLE IF EXISTS pg_temp.personal_workspace_backfill",
      # Reserve a workspace id per user first, so the workspace and its owner
      # row can be inserted set-based and still be paired up.
      """
      CREATE TEMPORARY TABLE personal_workspace_backfill AS
      SELECT u.id AS user_id,
             nextval(pg_get_serial_sequence('workspaces', 'id')) AS workspace_id
      FROM users u
      WHERE NOT EXISTS (
        SELECT 1 FROM workspace_members m
        WHERE m.user_id = u.id AND m.role = 'owner'
      )
      ORDER BY u.id
      """,
      """
      INSERT INTO workspaces (id, name, slug, personal, organization_id, inserted_at, updated_at)
      SELECT workspace_id,
             'Personal',
             'personal-' || user_id || '-' || substr(md5(random()::text || clock_timestamp()::text), 1, 8),
             true,
             NULL,
             (now() AT TIME ZONE 'UTC')::timestamp(0),
             (now() AT TIME ZONE 'UTC')::timestamp(0)
      FROM personal_workspace_backfill
      """,
      """
      INSERT INTO workspace_members (workspace_id, user_id, role, inserted_at, updated_at)
      SELECT workspace_id,
             user_id,
             'owner',
             (now() AT TIME ZONE 'UTC')::timestamp(0),
             (now() AT TIME ZONE 'UTC')::timestamp(0)
      FROM personal_workspace_backfill
      """,
      "DROP TABLE pg_temp.personal_workspace_backfill",
      # Boards with an owner row (at most one per board) go to that owner.
      """
      UPDATE boards b
      SET workspace_id = m.workspace_id
      FROM board_users bu
      JOIN workspace_members m ON m.user_id = bu.user_id AND m.role = 'owner'
      WHERE bu.board_id = b.id
        AND bu.access = 'owner'
        AND b.workspace_id IS NULL
      """,
      # Ownerless boards go to their earliest remaining member.
      """
      UPDATE boards b
      SET workspace_id = m.workspace_id
      FROM (
        SELECT DISTINCT ON (bu.board_id) bu.board_id, bu.user_id
        FROM board_users bu
        ORDER BY bu.board_id, bu.inserted_at, bu.id
      ) earliest
      JOIN workspace_members m ON m.user_id = earliest.user_id AND m.role = 'owner'
      WHERE earliest.board_id = b.id
        AND b.workspace_id IS NULL
      """,
      # Memberless boards go to the earliest enabled site admin.
      """
      DO $$
      DECLARE
        memberless integer;
        admin_workspace_id bigint;
      BEGIN
        SELECT count(*) INTO memberless
        FROM boards b
        WHERE b.workspace_id IS NULL
          AND NOT EXISTS (SELECT 1 FROM board_users bu WHERE bu.board_id = b.id);

        IF memberless = 0 THEN
          RETURN;
        END IF;

        SELECT m.workspace_id INTO admin_workspace_id
        FROM users u
        JOIN workspace_members m ON m.user_id = u.id AND m.role = 'owner'
        WHERE u.type = 'admin' AND u.disabled_at IS NULL
        ORDER BY u.inserted_at, u.id
        LIMIT 1;

        IF admin_workspace_id IS NULL THEN
          RAISE EXCEPTION '% board(s) have no members and there is no enabled site admin to hold them. Enable or create a site admin, then run the migration again.', memberless;
        END IF;

        UPDATE boards b
        SET workspace_id = admin_workspace_id
        WHERE b.workspace_id IS NULL
          AND NOT EXISTS (SELECT 1 FROM board_users bu WHERE bu.board_id = b.id);
      END
      $$
      """
    ]
  end

  defp log_counts do
    %{rows: [[workspaces, placed, unplaced]]} =
      repo().query!("""
      SELECT (SELECT count(*) FROM workspaces WHERE personal),
             (SELECT count(*) FROM boards WHERE workspace_id IS NOT NULL),
             (SELECT count(*) FROM boards WHERE workspace_id IS NULL)
      """)

    Logger.info(
      "Personal workspace backfill: #{workspaces} personal workspaces, " <>
        "#{placed} boards in a workspace, #{unplaced} boards without one"
    )
  end
end
