# Lean Metrics Reporting Dashboard

## Overview

Add a reporting dashboard to Stride that displays lean metrics for task flow analysis with PDF export capability.

## Requirements Summary

**Metrics to track:**
- **Throughput**: Tasks completed per time period
- **Cycle Time**: `claimed_at` → `completed_at` (active work time)
- **Lead Time**: `inserted_at` → `completed_at/reviewed_at` (total time in system)
- **Human Wait Time**: Time in review column + time in backlog awaiting triage

**Dashboard structure:**
- Main dashboard with summary stat cards (avg, median)
- Links to drill-down pages for each metric (charts + detailed tables)
- Drill-down pages exportable to PDF

**Filtering:**
- Board-scoped with agent breakdown
- Time ranges: 7/30/90 days presets
- Weekend exclusion toggle

**Access:** All board members can view their board's metrics

---

## Architecture Decisions

### 1. Calculate on-the-fly (not pre-aggregated)
Task volume per board is manageable. Avoids sync complexity. Add indexes for performance.

### 2. Server-side PDF with `chromic_pdf`
Renders HTML/CSS identically to browser. Charts work perfectly. Well-maintained library.

### 3. CSS-based bar charts
No JavaScript dependency - works in browser and PDF. Simple Tailwind implementation.

### 4. Separate LiveViews with shared components
One LiveView per page, shared `components.ex` for stat cards, charts, filters.

---

## Implementation Phases

### Phase 1: Foundation (Context Module + Database)

**Create `lib/kanban/metrics.ex`:**
```elixir
defmodule Kanban.Metrics do
  def get_dashboard_summary(board_id, opts \\ [])
  def get_throughput(board_id, opts \\ [])
  def get_cycle_time_stats(board_id, opts \\ [])
  def get_lead_time_stats(board_id, opts \\ [])
  def get_wait_time_stats(board_id, opts \\ [])
end
```

Options: `time_range: :last_7_days | :last_30_days | :last_90_days`, `agent_name: nil | "name"`, `exclude_weekends: true | false`

**Create `lib/kanban/metrics/calculations.ex`:**
- Statistical functions (average, median, percentiles)
- Weekend exclusion logic
- Time period grouping

**Create migration for indexes:**
```elixir
create index(:tasks, [:column_id, :completed_at])
create index(:tasks, [:column_id, :claimed_at])
```

### Phase 2: Main Dashboard LiveView

**Create files:**
- `lib/kanban_web/live/metrics_live/dashboard.ex`
- `lib/kanban_web/live/metrics_live/dashboard.html.heex`
- `lib/kanban_web/live/metrics_live/components.ex`

**Components to build:**
- `stat_card/1` - Metric card with value, trend indicator, link to drill-down
- `time_range_filter/1` - 7/30/90 day buttons
- `agent_filter/1` - Dropdown to filter by agent
- `weekend_toggle/1` - Checkbox for weekend exclusion

**Add route in `router.ex` (line ~119, within `:require_authenticated_user` live_session):**
```elixir
live "/boards/:id/metrics", MetricsLive.Dashboard, :index
```

**Add navigation link in `board_live/index.html.heex` (line ~109, alongside edit link):**
```heex
<.link
  navigate={~p"/boards/#{board}/metrics"}
  class="text-base-content opacity-40 hover:text-blue-600 hover:opacity-100 transition-colors duration-200 p-1 hover:bg-blue-50 rounded-lg"
  title={gettext("View Metrics")}
>
  <.icon name="hero-chart-bar" class="h-5 w-5" />
</.link>
```

### Phase 3: Drill-Down Pages

**Create 4 drill-down LiveViews:**
- `lib/kanban_web/live/metrics_live/throughput.ex` + `.html.heex`
- `lib/kanban_web/live/metrics_live/cycle_time.ex` + `.html.heex`
- `lib/kanban_web/live/metrics_live/lead_time.ex` + `.html.heex`
- `lib/kanban_web/live/metrics_live/wait_time.ex` + `.html.heex`

**Each drill-down includes:**
- CSS-based bar chart showing trend over time
- Summary stats table (avg, median, min, max, p90)
- Detailed task table with individual values
- Same filter controls as dashboard
- "Export to PDF" button

**Add routes:**
```elixir
live "/boards/:id/metrics/throughput", MetricsLive.Throughput, :index
live "/boards/:id/metrics/cycle-time", MetricsLive.CycleTime, :index
live "/boards/:id/metrics/lead-time", MetricsLive.LeadTime, :index
live "/boards/:id/metrics/wait-time", MetricsLive.WaitTime, :index
```

**Add bar_chart component:**
```heex
def bar_chart(assigns) do
  ~H"""
  <div class="h-40 flex items-end gap-1">
    <%= for {value, label} <- @data do %>
      <div class="flex-1 flex flex-col items-center">
        <div
          class="w-full bg-primary rounded-t"
          style={"height: #{value / @max * 100}%"}
        />
        <span class="text-xs mt-1 opacity-60"><%= label %></span>
      </div>
    <% end %>
  </div>
  """
end
```

### Phase 4: PDF Export

**Add dependency to `mix.exs`:**
```elixir
{:chromic_pdf, "~> 1.17"}
```

**Create `lib/kanban_web/controllers/metrics_pdf_controller.ex`:**
- Fetch metric data using same context functions
- Render print-optimized template to HTML string
- Convert to PDF with ChromicPDF
- Return as download

**Create print templates in `lib/kanban_web/controllers/metrics_pdf_html/`:**
- `throughput.html.heex`
- `cycle_time.html.heex`
- `lead_time.html.heex`
- `wait_time.html.heex`

**Add route:**
```elixir
get "/boards/:id/metrics/:metric/export", MetricsPdfController, :export
```

### Phase 5: Testing

**Create `test/kanban/metrics_test.exs`:**
- Test each calculation with sample data
- Test filter application
- Test weekend exclusion logic

**Create `test/kanban_web/live/metrics_live/dashboard_test.exs`:**
- Test mount with valid board
- Test filter events
- Test access control (board members only)

---

## File Structure

```
lib/
  kanban/
    metrics.ex                    # Main context
    metrics/
      calculations.ex             # Statistical functions
  kanban_web/
    live/
      metrics_live/
        dashboard.ex              # Main dashboard
        dashboard.html.heex
        throughput.ex             # Throughput drill-down
        throughput.html.heex
        cycle_time.ex             # Cycle time drill-down
        cycle_time.html.heex
        lead_time.ex              # Lead time drill-down
        lead_time.html.heex
        wait_time.ex              # Wait time drill-down
        wait_time.html.heex
        components.ex             # Shared components
    controllers/
      metrics_pdf_controller.ex   # PDF export
      metrics_pdf_html/
        throughput.html.heex
        cycle_time.html.heex
        lead_time.html.heex
        wait_time.html.heex
```

---

## Key Files to Modify

- [router.ex](lib/kanban_web/router.ex) - Add metrics routes (~line 119)
- [board_live/index.html.heex](lib/kanban_web/live/board_live/index.html.heex) - Add metrics link (~line 109)
- [mix.exs](mix.exs) - Add chromic_pdf dependency

---

## Metric Calculations

**Throughput:**
```sql
SELECT date_trunc('day', completed_at), count(*)
FROM tasks t JOIN columns c ON t.column_id = c.id
WHERE c.board_id = ? AND completed_at BETWEEN ? AND ?
GROUP BY 1
```

**Cycle Time:**
```sql
SELECT EXTRACT(EPOCH FROM (completed_at - claimed_at)) / 3600 as hours
FROM tasks t JOIN columns c ON t.column_id = c.id
WHERE c.board_id = ? AND claimed_at IS NOT NULL AND completed_at IS NOT NULL
```

**Lead Time:**
```sql
SELECT EXTRACT(EPOCH FROM (COALESCE(reviewed_at, completed_at) - inserted_at)) / 3600 as hours
FROM tasks t JOIN columns c ON t.column_id = c.id
WHERE c.board_id = ? AND completed_at IS NOT NULL
```

**Human Wait Time:**
- Review wait: `reviewed_at - completed_at` (when `needs_review = true`)
- Backlog wait: `claimed_at - inserted_at` (time before work started)

---

## Verification

1. Create test board with sample completed tasks
2. Navigate to `/boards/:id/metrics` - verify summary cards display
3. Click through to each drill-down page
4. Test filter controls (time range, agent, weekends)
5. Export each report to PDF and verify formatting
6. Run `mix test test/kanban/metrics_test.exs`
7. Run `mix test test/kanban_web/live/metrics_live/`
