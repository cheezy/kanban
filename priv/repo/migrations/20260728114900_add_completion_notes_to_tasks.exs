defmodule Kanban.Repo.Migrations.AddCompletionNotesToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :completion_notes, :text
    end
  end
end
