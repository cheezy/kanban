defmodule Kanban.Repo.Migrations.AddTasksColumnIdUpdatedAtIndex do
  use Ecto.Migration

  # The /agents roster fetch (`Kanban.Agents.fetch_tasks/1`) is the most
  # frequently executed query on `/agents` — every load and every debounced
  # refresh. It scopes the `tasks` table to the viewer's boards through the
  # column-membership join (`tasks.column_id -> columns -> board_users`),
  # optionally bounds `updated_at` to a trailing local-day window, and always
  # `ORDER BY updated_at DESC LIMIT 5000`.
  #
  # The only supporting index today is the single-column btree on `updated_at`
  # (20260709103500). For a BOARD-SCOPED fetch that index is global: the best
  # available plan is a backward scan of `updated_at` across EVERY tenant's
  # tasks, probing the membership join per row and discarding non-member rows
  # until the cap fills. Its cost therefore grows with the total database size
  # rather than the viewer's own data — it degrades exactly when many workspaces
  # share the table, because most scanned rows belong to other tenants.
  #
  # A composite btree on `(column_id, updated_at)` lets the planner drive from
  # the viewer's own columns instead: resolve the member board's column ids, then
  # range-scan each column's `updated_at` slice (already ordered within the
  # column), sort/merge and cap only tenant rows. Cost becomes proportional to
  # the viewer's data, not the whole table. This mirrors the established
  # `(column_id, completed_at)` / `(column_id, claimed_at)` composites in
  # 20260205211333 that serve the board-scoped metrics reads. It also directly
  # fits the `board_id`-filtered variant (`Agents.filter_by_board/2` restricts
  # `column_id` via a subquery, then orders by `updated_at`).
  #
  # The existing single-column `updated_at` index is deliberately KEPT: it still
  # serves the unscoped (nil-scope) fetches — e.g. `list_agents/1` without a
  # scope — and any global `updated_at` ordering, which the composite's
  # `column_id`-leading key cannot support.
  #
  # `tasks` is a hot production table, so create the index concurrently to avoid
  # taking a write lock during the migration. The index is intentionally NOT
  # partial on the `type <> 'goal'` exclusion: that predicate arrives as a query
  # parameter, and a partial-index predicate on it would make planner usage
  # fragile.
  def change do
    create index(:tasks, [:column_id, :updated_at], concurrently: true)
  end

  # Concurrent index creation cannot run inside a transaction.
  @disable_ddl_transaction true
  @disable_migration_lock true
end
