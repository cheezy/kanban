defmodule Kanban.Repo.Migrations.MakeTaskIdentifierBoardScoped do
  use Ecto.Migration

  def up do
    # Drop the global unique index on identifier
    drop_if_exists unique_index(:tasks, [:identifier])

    # We can't create a unique index directly on [:column_id, :identifier] that references board_id
    # Instead, we'll enforce uniqueness at the application level
    # and create a non-unique index for better query performance

    # Create an index to help with lookups (not unique, since we check at app level)
    create index(:tasks, [:identifier])
  end

  def down do
    # Remove the non-unique index
    drop_if_exists index(:tasks, [:identifier])

    # Restore the global unique index
    create unique_index(:tasks, [:identifier])
  end
end
