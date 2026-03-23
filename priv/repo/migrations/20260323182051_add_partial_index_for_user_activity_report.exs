defmodule Kanban.Repo.Migrations.AddPartialIndexForUserActivityReport do
  use Ecto.Migration

  def change do
    create index(:metrics_events, ["((metadata->>'user_id')::integer)"],
             name: :metrics_events_task_user_id_int_index,
             where: "metric_name LIKE 'kanban.api.task_%' AND metadata->>'user_id' ~ '^[0-9]+$'",
             concurrently: true
           )
  end

  # Concurrent index creation cannot run inside a transaction
  @disable_ddl_transaction true
  @disable_migration_lock true
end
