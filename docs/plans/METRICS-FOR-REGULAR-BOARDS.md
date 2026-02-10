# Enable Metrics for Non-AI-Optimized Boards

## Context

Metrics are currently restricted to AI-optimized boards via `board.ai_optimized_board` checks in the dashboard and all 4 metric LiveViews. This was done because AI-optimized boards have agent-specific fields (`claimed_at`, `reviewed_at`, `completed_by_agent`) that non-AI boards lack.

However, regular boards DO have:
- `completed_at` — set automatically when a task is dragged to "Done" (via `determine_status_for_column/2` in `tasks.ex:1037`)
- `inserted_at` — always set on creation
- `task_history` records — every cross-column move creates a `:move` history entry with `from_column`, `to_column`, and `inserted_at` timestamp

This means we can derive timing data for regular boards using TaskHistory:
- **Cycle Time**: Use the first move INTO a "work-in-progress" column as a proxy for `claimed_at`
- **Backlog Wait**: Use the first move OUT of the initial column as a proxy for when work started

## Approach: Board-Type-Aware Metrics

The Metrics context will accept a `board_type` option that determines which query strategy to use. AI-optimized boards continue using direct timestamp fields. Regular boards use TaskHistory-based subqueries to derive equivalent timestamps.

## Files to Modify

| File | Change |
|------|--------|
| `lib/kanban/metrics.ex` | Add `board_type` option, add TaskHistory-based query variants for cycle time and wait time |
| `lib/kanban_web/live/metrics_live/dashboard.ex` | Remove AI-only guard, pass board type, conditionally hide agent filter |
| `lib/kanban_web/live/metrics_live/throughput.ex` | Pass board type to queries, conditionally hide agent filter |
| `lib/kanban_web/live/metrics_live/cycle_time.ex` | Remove AI-only guard, add board-type dispatch, use TaskHistory queries for regular boards |
| `lib/kanban_web/live/metrics_live/lead_time.ex` | Remove AI-only guard (queries already work — uses `inserted_at` → `completed_at`) |
| `lib/kanban_web/live/metrics_live/wait_time.ex` | Remove AI-only guard, add board-type dispatch, adapt sections for regular boards |
| `lib/kanban_web/controllers/metrics_pdf_controller.ex` | Remove AI-only guard, pass board type |
| `lib/kanban_web/live/metrics_live/dashboard.html.heex` | Conditionally hide agent filter for regular boards |
| `lib/kanban_web/live/metrics_live/throughput.html.heex` | Conditionally hide agent filter/column for regular boards |
| `lib/kanban_web/live/metrics_live/cycle_time.html.heex` | Conditionally hide agent filter/column, relabel "Claimed" → "Started" for regular boards |
| `lib/kanban_web/live/metrics_live/lead_time.html.heex` | Conditionally hide agent filter/column for regular boards |
| `lib/kanban_web/live/metrics_live/wait_time.html.heex` | Adapt sections — hide Review Wait for regular boards, relabel Backlog Wait |
| `test/kanban_web/live/metrics_live/*_test.exs` | Add tests for regular board metrics |
| `test/kanban/metrics_test.exs` | Add tests for TaskHistory-based queries |

## Step 1: Metrics Context — Board-Type-Aware Queries

### 1a. Add helper to detect board type

In `lib/kanban/metrics.ex`, all public functions already receive `board_id`. Add an internal helper:

```elixir
defp board_ai_optimized?(board_id) do
  from(c in Kanban.Boards.Column,
    join: b in assoc(c, :board),
    where: b.id == ^board_id,
    select: b.ai_optimized_board,
    limit: 1
  )
  |> Repo.one()
  |> Kernel.||(false)
end
```

Each metric function will call this once and branch accordingly.

### 1b. Throughput — No changes needed

`get_throughput/2` uses `completed_at` which is set on both board types. The query works as-is.

### 1c. Lead Time — No changes needed

`get_lead_time_stats/2` uses `inserted_at` → `completed_at`, both available on regular boards.

### 1d. Cycle Time — Add TaskHistory-based variant

For regular boards, "cycle time" = time from when task first moved into a non-initial column (started work) to `completed_at`.

Add a new private function `get_cycle_time_stats_from_history/3`:

```elixir
defp get_cycle_time_stats_from_history(board_id, start_date, exclude_weekends) do
  # Subquery: find the earliest :move history entry per task
  # that represents work starting (first move out of initial column)
  first_move_subquery =
    from th in Kanban.Tasks.TaskHistory,
      where: th.type == :move,
      group_by: th.task_id,
      select: %{task_id: th.task_id, started_at: min(th.inserted_at)}

  query =
    Task
    |> join(:inner, [t], c in assoc(t, :column))
    |> join(:inner, [t], fm in subquery(first_move_subquery), on: fm.task_id == t.id)
    |> where([t, c], c.board_id == ^board_id)
    |> where([t], not is_nil(t.completed_at))
    |> where([t], t.completed_at >= ^start_date)
    |> where([t], t.type != ^:goal)
    |> select([t, c, fm], %{
      cycle_time_seconds:
        fragment("EXTRACT(EPOCH FROM (? - ?))", t.completed_at, fm.started_at),
      completed_at: t.completed_at,
      claimed_at: fm.started_at
    })

  results = Repo.all(query)
  # Apply weekend filter + calculate stats (reuse existing helpers)
end
```

Update `get_cycle_time_stats/2` to branch:

```elixir
def get_cycle_time_stats(board_id, opts \\ []) do
  time_range = Keyword.get(opts, :time_range, :last_30_days)
  exclude_weekends = Keyword.get(opts, :exclude_weekends, false)
  start_date = get_start_date(time_range)

  if board_ai_optimized?(board_id) do
    # existing query using claimed_at field
    agent_name = Keyword.get(opts, :agent_name)
    # ... existing code ...
  else
    get_cycle_time_stats_from_history(board_id, start_date, exclude_weekends)
  end
end
```

### 1e. Wait Time — Adapt for regular boards

For regular boards:
- **Review Wait**: Not applicable (no review step). Return empty stats `{:ok, %{review_wait: empty_stats, backlog_wait: ...}}`.
- **Backlog Wait**: Time from `inserted_at` to first move (from TaskHistory). Similar subquery approach as cycle time.

```elixir
defp get_wait_time_stats_from_history(board_id, start_date, exclude_weekends) do
  first_move_subquery =
    from th in Kanban.Tasks.TaskHistory,
      where: th.type == :move,
      group_by: th.task_id,
      select: %{task_id: th.task_id, first_moved_at: min(th.inserted_at)}

  backlog_query =
    Task
    |> join(:inner, [t], c in assoc(t, :column))
    |> join(:inner, [t], fm in subquery(first_move_subquery), on: fm.task_id == t.id)
    |> where([t, c], c.board_id == ^board_id)
    |> where([t], t.inserted_at >= ^start_date)
    |> where([t], t.type != ^:goal)
    |> select([t, c, fm], %{
      wait_time_seconds:
        fragment("EXTRACT(EPOCH FROM (? - ?))", fm.first_moved_at, t.inserted_at),
      start_time: t.inserted_at,
      end_time: fm.first_moved_at
    })

  backlog_results = backlog_query |> Repo.all() |> apply_weekend_filter(exclude_weekends)
  empty_stats = %{average_hours: 0, median_hours: 0, min_hours: 0, max_hours: 0, count: 0}

  with {:ok, backlog_stats} <- calculate_wait_time_stats(backlog_results) do
    {:ok, %{review_wait: empty_stats, backlog_wait: backlog_stats}}
  end
end
```

### 1f. Agent filter — Return empty for regular boards

Update `get_agents/1`:

```elixir
def get_agents(board_id) do
  if board_ai_optimized?(board_id) do
    # existing query
  else
    {:ok, []}
  end
end
```

### 1g. Dashboard summary — Branch per metric

`get_dashboard_summary/2` calls all 4 metrics. The branching happens inside each metric function, so no changes needed here.

## Step 2: LiveView Task Queries — Board-Type Variants

The LiveViews have their own task-fetching queries (for the detailed task tables). These also need variants.

### 2a. Cycle Time LiveView (`cycle_time.ex`)

In `get_cycle_time_tasks/2`, the current query requires `claimed_at`. Add a variant:

```elixir
defp get_cycle_time_tasks(board_id, opts) do
  if board_ai_optimized?(board_id) do
    get_cycle_time_tasks_ai(board_id, opts)
  else
    get_cycle_time_tasks_regular(board_id, opts)
  end
end
```

`get_cycle_time_tasks_regular` joins TaskHistory to get the first move timestamp as "started_at", returning it in the `:claimed_at` field so the existing template works without changes to field names.

### 2b. Wait Time LiveView (`wait_time.ex`)

- `get_review_wait_tasks/2`: Return `[]` for regular boards (no review step).
- `get_backlog_wait_tasks/2`: Use TaskHistory first-move subquery instead of `claimed_at`.

### 2c. Throughput LiveView (`throughput.ex`)

Already works for regular boards (no AI check). Task list queries use `completed_by_agent` for display — for regular boards, this will be `nil`, so display "—" instead of "Agent Unknown".

### 2d. Lead Time LiveView (`lead_time.ex`)

Queries already work (uses `inserted_at` → `completed_at`). Just remove the AI guard.

### 2e. Add board-type helper to each LiveView

Store `board.ai_optimized_board` in socket assigns and pass it through.

## Step 3: Remove AI-Only Guards

Remove the `if board.ai_optimized_board do ... else redirect` pattern from:

| File | Line |
|------|------|
| `dashboard.ex` | 23 |
| `cycle_time.ex` | 29 |
| `lead_time.ex` | 29 |
| `wait_time.ex` | 29 |
| `metrics_pdf_controller.ex` | 25 |

Each becomes a straight-through flow — load data regardless of board type.

## Step 4: Template Adaptations

### 4a. Conditionally hide agent filter

In all 4 metric templates and the dashboard template, wrap the agent filter `<select>` in:

```heex
<div :if={@board.ai_optimized_board}>
  <!-- existing agent filter select -->
</div>
```

### 4b. Conditionally hide "Agent" column in task tables

In throughput, cycle time, and lead time task detail tables, wrap the Agent column header and cell:

```heex
<th :if={@board.ai_optimized_board}>Agent</th>
...
<td :if={@board.ai_optimized_board}>{task.completed_by_agent || "—"}</td>
```

### 4c. Relabel "Claimed" in cycle time for regular boards

```heex
<th>{if @board.ai_optimized_board, do: "Claimed", else: "Started"}</th>
```

### 4d. Wait Time template — hide Review Wait section for regular boards

Wrap the entire Review Wait section in `:if={@board.ai_optimized_board}`. Show only Backlog Wait (relabeled as "Queue Wait" for regular boards to avoid agent-specific terminology).

### 4e. Dashboard — adapt Wait Time card for regular boards

Show review wait as "N/A" or hide it for regular boards.

## Step 5: PDF Controller Adaptations

Remove the AI guard in `export/2` (line 25). The `load_metric_data` functions call `Metrics.*` which already branch internally. For task detail queries in the controller, apply the same board-type branching as the LiveViews.

The `generate_filename/3` function needs no changes.

## Step 6: Tests

### 6a. Metrics context tests (`test/kanban/metrics_test.exs`)

Add a `describe "regular board metrics"` section:
- Create a regular board (non-AI) with columns and tasks
- Create TaskHistory `:move` records to simulate column transitions
- Set `completed_at` on tasks (simulating drag to Done)
- Test `get_throughput/2` returns correct counts
- Test `get_lead_time_stats/2` returns correct stats
- Test `get_cycle_time_stats/2` derives cycle time from TaskHistory
- Test `get_wait_time_stats/2` returns empty review_wait and correct backlog_wait
- Test `get_agents/1` returns `[]` for regular boards

### 6b. LiveView tests (`test/kanban_web/live/metrics_live/*_test.exs`)

Add tests for each metric page with a regular board:
- Dashboard loads without redirect
- Throughput page shows task data, no agent filter
- Cycle time page shows TaskHistory-derived data
- Lead time page works normally
- Wait time page shows only Backlog/Queue Wait section

### 6c. Update existing tests

Some tests may assert on "Metrics are only available for AI-optimized boards" flash messages — update or remove these.

## Verification

1. `mix compile --warnings-as-errors` — clean compile
2. `mix test test/kanban/metrics_test.exs` — context tests pass
3. `mix test test/kanban_web/live/metrics_live/` — LiveView tests pass
4. `mix test test/kanban_web/controllers/metrics_pdf_controller_test.exs` — PDF tests pass
5. `mix test` — full suite passes
6. `mix credo` — no style issues
7. Manual: create a regular board, add tasks, drag some to Done, visit metrics pages and verify all 4 work
