defmodule Kanban.Repo.Migrations.CreateTaskHistory do
  use Ecto.Migration

  def change do
    create table(:task_history) do
      add :type, :string, null: false
      add :from_column, :string
      add :to_column, :string
      add :task_id, references(:tasks, on_delete: :delete_all), null: false

      timestamps(updated_at: false)
    end

    create index(:task_history, [:task_id])
    create index(:task_history, [:type])
  end
end
