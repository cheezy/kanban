defmodule Kanban.Repo.Migrations.AddReviewReportToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :review_report, :text
    end
  end
end
