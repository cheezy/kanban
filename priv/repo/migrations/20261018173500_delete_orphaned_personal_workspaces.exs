defmodule Kanban.Repo.Migrations.DeleteOrphanedPersonalWorkspaces do
  @moduledoc """
  Deletes the personal workspaces that account deletions left without an owner
  before D381. Deleting a user removed their owner row (the
  `workspace_members.user_id` cascade) but not the workspace, so each delete
  left one personal workspace nobody could reach.

  * A personal workspace with no owner row and no boards is deleted.
  * One with no owner row that still holds a board is kept and counted in the
    log. `boards.workspace_id` restricts the delete, and moving boards out is
    W2218's job, so the migration never fails on one.

  The work is set-based SQL only. `cleanup_statements/0` is public so
  `test/kanban/workspaces/orphan_cleanup_migration_test.exs` runs exactly the
  statements `up/0` does. Running them twice changes nothing.
  """

  use Ecto.Migration

  require Logger

  def up do
    Enum.each(cleanup_statements(), &execute/1)
    execute(&log_kept/0)
  end

  # One-way cleanup: a deleted orphan had no owner and no boards, so nobody
  # could reach it and there is nothing to restore.
  def down, do: :ok

  def cleanup_statements do
    [
      """
      DELETE FROM workspaces w
      WHERE w.personal
        AND NOT EXISTS (
          SELECT 1 FROM workspace_members m WHERE m.workspace_id = w.id AND m.role = 'owner'
        )
        AND NOT EXISTS (SELECT 1 FROM boards b WHERE b.workspace_id = w.id)
      """
    ]
  end

  defp log_kept do
    %{rows: [[kept]]} =
      repo().query!("""
      SELECT count(*) FROM workspaces w
      WHERE w.personal
        AND NOT EXISTS (
          SELECT 1 FROM workspace_members m WHERE m.workspace_id = w.id AND m.role = 'owner'
        )
        AND EXISTS (SELECT 1 FROM boards b WHERE b.workspace_id = w.id)
      """)

    Logger.info("Orphaned personal workspace cleanup: #{kept} kept because they hold boards")
  end
end
