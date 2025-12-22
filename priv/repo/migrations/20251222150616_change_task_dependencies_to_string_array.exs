defmodule Kanban.Repo.Migrations.ChangeTaskDependenciesToStringArray do
  use Ecto.Migration

  def up do
    # Change dependencies column from integer array to text array
    alter table(:tasks) do
      remove :dependencies
      add :dependencies, {:array, :string}, default: []
    end
  end

  def down do
    # Revert back to integer array
    alter table(:tasks) do
      remove :dependencies
      add :dependencies, {:array, :integer}, default: []
    end
  end
end
