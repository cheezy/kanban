defmodule Kanban.Repo.Migrations.AddPriorityChangeToTaskHistory do
  use Ecto.Migration

  def change do
    alter table(:task_history) do
      add :from_priority, :string
      add :to_priority, :string
    end
  end
end
