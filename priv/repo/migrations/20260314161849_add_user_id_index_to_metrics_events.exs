defmodule Kanban.Repo.Migrations.AddUserIdIndexToMetricsEvents do
  use Ecto.Migration

  def change do
    create index(:metrics_events, ["((metadata->>'user_id'))"],
      name: :metrics_events_metadata_user_id_index
    )
  end
end
