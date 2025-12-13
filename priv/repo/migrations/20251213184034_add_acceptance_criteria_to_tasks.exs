defmodule Kanban.Repo.Migrations.AddAcceptanceCriteriaToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :acceptance_criteria, :text
    end
  end
end
