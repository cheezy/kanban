defmodule Kanban.Repo.Migrations.AddMetricsQueryIndexes do
  use Ecto.Migration

  def change do
    # Composite index for queries filtering by column_id and completed_at
    # Used by get_throughput, get_cycle_time_stats, get_lead_time_stats
    create index(:tasks, [:column_id, :completed_at])

    # Composite index for queries filtering by column_id and claimed_at
    # Used by get_cycle_time_stats and get_wait_time_stats
    create index(:tasks, [:column_id, :claimed_at])
  end
end
