# Elixir Optimization Plugin - Code Duplication Detection and Refactoring Guide

## What the Plugin Would Detect

The elixir-optimization plugin would scan for common duplication patterns in Phoenix LiveView applications and suggest refactoring opportunities. Here's what it would have detected in the metrics pages:

---

## Pattern 1: Duplicated Helper Functions Across LiveView Modules

### Detection Rule
When 3+ LiveView modules contain identical or near-identical private helper functions (especially formatting, parsing, and calculation functions), extract them to a shared module.

### What Was Detected

```elixir
# In cycle_time.ex, lead_time.ex, and wait_time.ex
defp format_time(%Decimal{} = seconds) do
  seconds |> Decimal.to_float() |> format_time()
end

defp format_time(seconds) when is_number(seconds) do
  # ... 20 lines of formatting logic ...
end

defp format_datetime(datetime) do
  # ... 10 lines of datetime formatting ...
end

defp parse_time_range(time_range) do
  # ... 8 lines of parsing logic ...
end

# 10+ more duplicated functions
```

### Refactoring Action
**Created:** `lib/kanban_web/live/metrics_live/helpers.ex`
- Extracted all common formatting functions (`format_time`, `format_time_hours`, `format_datetime`, etc.)
- Extracted all parsing functions (`parse_time_range`, `parse_agent_name`, `parse_exclude_weekends`)
- Extracted all calculation functions (`calculate_trend_line`, `get_max_time`, `calculate_daily_times`)

**Result:** Eliminated ~370 lines of duplicated code across 3 modules

---

## Pattern 2: Duplicated Component Markup in Templates

### Detection Rule
When 2+ templates contain identical or near-identical HEEx markup blocks (>20 lines), especially with the same structure but different data, extract to a function component.

### What Was Detected

#### Filter Section Duplication
```heex
<!-- In cycle_time.html.heex and lead_time.html.heex -->
<div class="mt-8 bg-gradient-to-br from-white via-indigo-50/30...">
  <div class="flex items-center gap-3 mb-6...">
    <!-- 86 lines of identical filter UI -->
  </div>
  <form phx-change="filter_change">
    <!-- Time range select -->
    <!-- Agent select -->
    <!-- Weekend toggle -->
  </form>
</div>
```

#### Statistics Cards Duplication
```heex
<!-- In cycle_time.html.heex and lead_time.html.heex -->
<div class="mt-8 grid grid-cols-1 gap-6 lg:grid-cols-4">
  <div class="group bg-gradient-to-br from-white to-blue-50...">
    <!-- Average card -->
  </div>
  <div class="group bg-gradient-to-br from-white to-purple-50...">
    <!-- Median card -->
  </div>
  <!-- Min and Max cards - 136 total lines -->
</div>
```

#### Trend Chart Duplication
```heex
<!-- In cycle_time.html.heex and lead_time.html.heex -->
<div class="mt-8 bg-white dark:bg-zinc-800...">
  <svg viewBox="0 0 800 400"...>
    <!-- 100+ lines of identical SVG chart rendering -->
  </svg>
</div>
```

### Refactoring Action
**Created Components in:** `lib/kanban_web/live/metrics_live/components.ex`

1. **`metric_filters/1` component** - Unified filter UI
   - Replaced 86 lines × 2 templates = 172 lines with 6 lines of component calls

2. **`summary_stats/1` component** - Four-card statistics display
   - Replaced 136 lines × 2 templates = 272 lines with 1 line of component calls

3. **`trend_chart/1` component** - SVG trend visualization
   - Replaced 117 lines × 2 templates = 234 lines with 6 lines of component calls

**Result:** Reduced template code by ~650 lines while improving maintainability

---

## Pattern 3: Complex Functions with High ABC Complexity

### Detection Rule
When a function's ABC (Assignments, Branches, Calls) complexity exceeds 30, break it into smaller, focused helper functions.

### What Was Detected

```elixir
# In helpers.ex
def calculate_trend_line(daily_times) do
  n = length(daily_times)

  {sum_x, sum_y, sum_xy, sum_x_squared} =
    daily_times
    |> Enum.with_index()
    |> Enum.reduce({0.0, 0.0, 0.0, 0.0}, fn {day, index}, {sx, sy, sxy, sx2} ->
      x = index * 1.0
      y = day.average_hours
      {sx + x, sy + y, sxy + x * y, sx2 + x * x}
    end)

  slope = (n * sum_xy - sum_x * sum_y) / (n * sum_x_squared - sum_x * sum_x)
  intercept = (sum_y - slope * sum_x) / n

  %{slope: slope, intercept: intercept}
end
```

**ABC Complexity:** 41 (exceeds threshold of 30)

### Refactoring Action
Broke down into focused helper functions:

```elixir
def calculate_trend_line(daily_times) do
  n = length(daily_times)
  {sum_x, sum_y, sum_xy, sum_x_squared} = calculate_regression_sums(daily_times)

  slope = calculate_slope(n, sum_x, sum_y, sum_xy, sum_x_squared)
  intercept = calculate_intercept(n, sum_x, sum_y, slope)

  %{slope: slope, intercept: intercept}
end

defp calculate_regression_sums(daily_times) do
  # Focused on sum accumulation
end

defp calculate_slope(n, sum_x, sum_y, sum_xy, sum_x_squared) do
  # Focused on slope calculation
end

defp calculate_intercept(n, sum_x, sum_y, slope) do
  # Focused on intercept calculation
end
```

**New ABC Complexity:** <20 per function

**Result:** Passed credo strict checks with no warnings

---

## Pattern 4: Unused Helper Functions After Refactoring

### Detection Rule
After extracting duplicated code to shared modules, detect and remove wrapper functions that are no longer called.

### What Was Detected

```elixir
# In cycle_time.ex and lead_time.ex
defp get_max_cycle_time(daily_cycle_times), do: Helpers.get_max_time(daily_cycle_times)
defp calculate_trend_line(daily_cycle_times), do: Helpers.calculate_trend_line(daily_cycle_times)
```

**Compiler Warning:** "function get_max_cycle_time/1 is unused"

### Refactoring Action
Removed unused wrapper functions since templates now call `Helpers` functions directly through components.

**Result:** Clean compilation with no warnings

---

## Plugin Detection Heuristics

The plugin would use these heuristics to identify refactoring opportunities:

### 1. Code Similarity Analysis
- **Threshold:** When 2+ files share >70% identical function implementations
- **Action:** Suggest creating a shared module
- **Confidence:** High when 3+ files share the same pattern

### 2. Template Markup Analysis
- **Threshold:** When 2+ templates share >50 consecutive identical lines
- **Action:** Suggest extracting to a function component
- **Confidence:** Very high when class names and structure match exactly

### 3. Cyclomatic Complexity
- **Threshold:** When function complexity exceeds configurable limits (default: 30 ABC)
- **Action:** Suggest breaking into smaller functions
- **Confidence:** Based on Credo complexity analysis

### 4. Unused Function Detection
- **Threshold:** When private functions are never called
- **Action:** Suggest removal
- **Confidence:** Based on compiler warnings

---

## Best Practices Enforced

The plugin would enforce these Phoenix LiveView best practices:

1. **DRY Principle**
   - No function should be duplicated across 3+ modules
   - No template markup should be duplicated across 2+ templates

2. **Component Composition**
   - Extract UI patterns >20 lines into function components
   - Components should accept data via attributes, not hard-code values
   - Use slots for flexible content placement

3. **Module Organization**
   - Create `*_helpers.ex` modules for shared business logic
   - Create `*_components.ex` modules for shared UI components
   - Keep LiveView modules focused on orchestration, not implementation

4. **Complexity Management**
   - Keep function complexity below 30 ABC score
   - Break complex algorithms into named helper functions
   - Each function should have a single, clear responsibility

5. **Code Quality**
   - All code must pass `mix credo --strict`
   - All tests must pass after refactoring
   - No compiler warnings allowed

---

## Expected Outcomes

After applying these refactoring patterns:

- ✅ **-500+ lines** of duplicated code eliminated
- ✅ **3-4× easier** to update shared functionality (change once, not 3-4 times)
- ✅ **Faster development** when adding new metric views
- ✅ **Better testability** with focused, single-purpose functions
- ✅ **Cleaner codebase** passing all quality checks

---

## Plugin Invocation Triggers

The plugin would proactively suggest refactoring when:

1. **On File Save:** Detect duplication in the file being edited
2. **On Module Creation:** Warn if creating a LiveView module similar to existing ones
3. **On Template Edit:** Detect markup duplication across templates
4. **On CI/CD:** Run as part of quality checks before merge
5. **On Demand:** Via command like `mix elixir_optimization.analyze`

---

## Conclusion

The elixir-optimization plugin would have detected these patterns through static analysis, then guided the refactoring process with:

1. **Automatic detection** of duplicated code patterns
2. **Concrete suggestions** with code examples
3. **Refactoring templates** showing the target structure
4. **Verification** that changes pass all quality checks

This systematic approach to code quality ensures Phoenix LiveView applications remain maintainable and follow best practices as they grow.
