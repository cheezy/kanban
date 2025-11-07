defmodule Kanban.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  def change do
    create table(:tasks) do
      add :title, :string, null: false
      add :description, :text
      add :position, :integer, null: false
      add :column_id, references(:columns, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:tasks, [:column_id])
    create unique_index(:tasks, [:column_id, :position])
  end
end
