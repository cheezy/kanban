defmodule Kanban.Repo.Migrations.RequireBoardWorkspace do
  @moduledoc """
  Makes `boards.workspace_id` NOT NULL (W2217), once the previous migration has
  put every board in a workspace.

  This is its own migration so a partial backfill fails here, with a message
  naming how many boards were missed, rather than inside the backfill.
  `require_statements/0` is public so the test runs exactly these statements.
  """

  use Ecto.Migration

  def up do
    Enum.each(require_statements(), &execute/1)
  end

  def down do
    execute "ALTER TABLE boards ALTER COLUMN workspace_id DROP NOT NULL"
  end

  @doc """
  The guard and the constraint, in order, as SQL statements.
  """
  def require_statements do
    [
      """
      DO $$
      DECLARE
        missing integer;
      BEGIN
        SELECT count(*) INTO missing FROM boards WHERE workspace_id IS NULL;

        IF missing > 0 THEN
          RAISE EXCEPTION '% board(s) still have no workspace. Run the personal workspace backfill before making boards.workspace_id NOT NULL.', missing;
        END IF;
      END
      $$
      """,
      "ALTER TABLE boards ALTER COLUMN workspace_id SET NOT NULL"
    ]
  end
end
