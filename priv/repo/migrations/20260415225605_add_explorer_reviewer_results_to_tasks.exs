defmodule Kanban.Repo.Migrations.AddExplorerReviewerResultsToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :explorer_result, :jsonb
      add :reviewer_result, :jsonb
    end
  end
end
