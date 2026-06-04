defmodule Kanban.Repo.Migrations.MakeTasksPositionIndexPartialOnArchived do
  use Ecto.Migration

  # The original full unique index on (column_id, position) (from
  # 20251107162821_create_tasks) constrains archived tasks too. Archived tasks
  # retain their last position forever, which both inflates a column's position
  # space and forces position-shift operations to renumber thousands of
  # invisible archived rows (causing DB-timeout reverts on large Done columns).
  # Replace it with a PARTIAL unique index that only enforces uniqueness for
  # live (non-archived) tasks, so archived rows neither collide with nor
  # constrain live positions and can be excluded from shifts entirely.
  def up do
    drop unique_index(:tasks, [:column_id, :position])
    create unique_index(:tasks, [:column_id, :position], where: "archived_at IS NULL")
  end

  def down do
    drop unique_index(:tasks, [:column_id, :position], where: "archived_at IS NULL")
    create unique_index(:tasks, [:column_id, :position])
  end
end
