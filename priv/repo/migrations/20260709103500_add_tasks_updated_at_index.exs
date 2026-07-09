defmodule Kanban.Repo.Migrations.AddTasksUpdatedAtIndex do
  use Ecto.Migration

  # The /agents roster fetch (`Kanban.Agents.fetch_tasks/1`) filters and orders
  # the `tasks` table by `updated_at`: every load applies the 60-day throughput
  # window (`updated_at >= window_start`) and, after D125, bounds the roster
  # fetch with `ORDER BY updated_at DESC LIMIT`. `updated_at` had no supporting
  # index, so both the range filter and the ordered limit forced a full-table
  # scan/sort. A plain btree on `updated_at` serves both. Board scoping is
  # applied via the columns/board_users join (already indexed), so a
  # single-column index on the tasks side is the correct support here.
  #
  # `tasks` is a hot production table, so create the index concurrently to avoid
  # locking writes during the migration.
  #
  # EXPLAIN evidence (hot roster query — the `:all_time` fetch after D125's cap):
  #   SELECT t0.id FROM tasks t0 WHERE t0.type <> 'goal'
  #   ORDER BY t0.updated_at DESC LIMIT 5000
  # Without this index the plan is `Limit -> Sort (updated_at DESC) -> Seq Scan`
  # — a full-table sort of the entire history on every /agents load. With the
  # index, `ORDER BY updated_at DESC LIMIT n` becomes a bounded backward index
  # scan (no sort node), reading ~n index entries and stopping. The same btree
  # also serves the `updated_at >= window_start` range filter that
  # `Agents.apply_window/2` applies on every load (the 60-day throughput fetch).
  # (On a small dev DB the planner still picks the trivially-cheap seq scan; the
  # index matters at production row counts, where the sort dominates.)
  def change do
    create index(:tasks, [:updated_at], concurrently: true)
  end

  # Concurrent index creation cannot run inside a transaction.
  @disable_ddl_transaction true
  @disable_migration_lock true
end
