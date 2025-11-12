defmodule Kanban.Repo.Migrations.CreateTaskComments do
  use Ecto.Migration

  def change do
    create table(:task_comments) do
      add :content, :text, null: false
      add :task_id, references(:tasks, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:task_comments, [:task_id])
  end
end
