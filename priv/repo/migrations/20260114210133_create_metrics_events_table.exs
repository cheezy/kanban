defmodule Kanban.Repo.Migrations.CreateMetricsEventsTable do
  use Ecto.Migration

  def change do
    create table(:metrics_events) do
      add :metric_name, :string, null: false
      add :measurement, :float, null: false
      add :metadata, :map, default: %{}
      add :recorded_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:metrics_events, [:metric_name])
    create index(:metrics_events, [:recorded_at])
    create index(:metrics_events, [:metric_name, :recorded_at])
  end
end
