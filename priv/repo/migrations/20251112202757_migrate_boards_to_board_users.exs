defmodule Kanban.Repo.Migrations.MigrateBoardsToBoardUsers do
  use Ecto.Migration

  def up do
    # Migrate existing boards to board_users with owner access
    execute """
    INSERT INTO board_users (board_id, user_id, access, inserted_at, updated_at)
    SELECT id, user_id, 'owner', inserted_at, updated_at
    FROM boards
    WHERE user_id IS NOT NULL
    """

    # Remove the user_id foreign key constraint and column from boards
    alter table(:boards) do
      remove :user_id
    end
  end

  def down do
    # Add back the user_id column
    alter table(:boards) do
      add :user_id, references(:users, on_delete: :delete_all)
    end

    # Migrate owners back to boards table
    execute """
    UPDATE boards
    SET user_id = (
      SELECT user_id
      FROM board_users
      WHERE board_users.board_id = boards.id
      AND board_users.access = 'owner'
      LIMIT 1
    )
    """
  end
end
