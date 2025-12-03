defmodule Kanban.Repo.Migrations.AddAssignmentToTaskHistory do
  use Ecto.Migration

  def change do
    alter table(:task_history) do
      add :from_user_id, references(:users, on_delete: :nilify_all)
      add :to_user_id, references(:users, on_delete: :nilify_all)
    end

    create index(:task_history, [:from_user_id])
    create index(:task_history, [:to_user_id])
  end
end
