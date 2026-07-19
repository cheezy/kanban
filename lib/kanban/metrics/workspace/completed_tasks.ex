defmodule Kanban.Metrics.Workspace.CompletedTasks do
  @moduledoc """
  The completed-task read and its derivations behind the workspace `/metrics`
  page. Extracted from `Kanban.Metrics.Workspace` (W1737) to keep that façade
  under the module-size guideline.

  One projected query (`fetch/3`) is the single source of completed-task data;
  five in-memory derivations reshape it into the KPI strip, the daily median
  cycle-time series, the daily p50 lead-time series, the daily throughput
  series, and the contributor leaderboard. The cycle-time and lead-time series
  share one bucketing builder (`daily_minutes_series/4`) parameterized by the
  per-day statistic, so the two differ only in which minutes function they
  apply. `overview_series/3` derives its four payloads from a single window-spanning
  fetch partitioned in memory, so a render issues one completed-task query rather
  than five. Each public function returns the exact shape its
  `Kanban.Metrics.Workspace` counterpart documents; the façade resolves scope
  and options, then hands this module the already-resolved `board_ids`,
  `window_days`, `timezone`, and `exclude_weekends?` flag.

  ### Weekend exclusion

  `exclude_weekends?` applies the same two strategies the board-level reads in
  `Kanban.Metrics` use, because the two kinds of number need different treatment:

    * **Durations** (cycle, lead, review wait) subtract the weekend *portion* of
      each individual interval. That math lives in
      `Kanban.Metrics.Workspace.Durations`, which this module delegates every
      per-task statistic to. A task claimed Friday and completed Monday keeps
      its weekday hours rather than being counted whole.
    * **Day-bucketed series** (cycle, lead, throughput) drop whole Saturday and
      Sunday buckets via the shared `Windows.day_range/3`. The series therefore
      gets shorter; the window still spans the same calendar days.

  A third rule applies to **count-based** measures only: tasks *completed* on a
  weekend are dropped (`reject_weekend_completions/3`) from the throughput count
  and the leaderboard. Without it a weekend completion would be invisible in the
  throughput chart — its bucket having been removed — while still inflating the
  per-day throughput KPI and a contributor's leaderboard tally.

  That rule deliberately does NOT reach the duration statistics. A task claimed
  Friday and completed Saturday still contributes its business-time cycle to the
  KPI strip, exactly as it does on the board pages, because dropping it would
  make the workspace and board report different numbers for the same task — the
  mismatch this feature exists to remove. (The day series need no such filter
  either way: they look up per-day buckets, so a weekend key is simply never
  read once the weekend days are gone from the range.)
  """

  import Ecto.Query, warn: false

  alias Kanban.Metrics.Workspace.Durations
  alias Kanban.Metrics.Workspace.Windows
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias Kanban.Timezone

  @workspace_agent_leaderboard_limit 6

  @doc """
  Derives the five completed-task payloads (`:kpis`, `:cycle_series`,
  `:lead_series`, `:throughput_series`, `:leaderboard`) from a single
  window-spanning fetch, partitioned in memory into the current and previous
  KPI windows. This is the read-collapsing path behind `overview/1`: one
  projected fetch covering `previous_start..now` replaces the six the
  individual reads would issue.
  """
  @spec overview_series([integer()], pos_integer(), String.t(), boolean()) :: %{
          kpis: map(),
          cycle_series: [%{date: Date.t(), minutes: non_neg_integer()}],
          lead_series: [%{date: Date.t(), minutes: non_neg_integer()}],
          throughput_series: [non_neg_integer()],
          leaderboard: [map()]
        }
  def overview_series(board_ids, window_days, timezone, exclude_weekends? \\ false) do
    now = DateTime.utc_now()
    current_start = Windows.local_day_start(window_days - 1, timezone)
    previous_start = Windows.local_day_start(2 * window_days - 1, timezone)

    {current, previous} =
      board_ids
      |> fetch(previous_start, now)
      |> partition_windows(current_start)

    current
    |> reject_weekend_completions(exclude_weekends?, timezone)
    |> series_bundle(window_days, timezone, exclude_weekends?)
    |> Map.put(:kpis, build_kpis(current, previous, window_days, timezone, exclude_weekends?))
  end

  # The four counted-set payloads. Takes the already weekend-filtered set, so
  # every measure here derives from exactly the same tasks; the KPI strip is
  # merged in by the caller because its durations deliberately use the
  # unfiltered set (see `build_kpis/5`).
  defp series_bundle(counted, window_days, timezone, exclude_weekends?) do
    %{
      cycle_series: cycle_series_from(counted, window_days, timezone, exclude_weekends?),
      lead_series: lead_series_from(counted, window_days, timezone, exclude_weekends?),
      throughput_series:
        throughput_series_from(counted, window_days, timezone, exclude_weekends?),
      leaderboard: leaderboard_from(counted)
    }
  end

  @doc """
  Derives the workspace KPI strip for the trailing window with delta percentages
  vs the previous equal-length window. Issues two window fetches (current and
  previous), mirroring `workspace_kpis/1`'s standalone read.
  """
  @spec kpis([integer()], pos_integer(), String.t(), boolean()) :: map()
  def kpis(board_ids, window_days, timezone, exclude_weekends? \\ false) do
    now = DateTime.utc_now()
    current_start = Windows.local_day_start(window_days - 1, timezone)
    previous_start = Windows.local_day_start(2 * window_days - 1, timezone)

    current = fetch(board_ids, current_start, now)
    previous = fetch(board_ids, previous_start, current_start)

    build_kpis(current, previous, window_days, timezone, exclude_weekends?)
  end

  @doc """
  Derives the daily median cycle-time series (oldest-to-newest) from the current
  trailing window's completed tasks.
  """
  @spec cycle_time_daily([integer()], pos_integer(), String.t(), boolean()) :: [
          %{date: Date.t(), minutes: non_neg_integer()}
        ]
  def cycle_time_daily(board_ids, window_days, timezone, exclude_weekends? \\ false) do
    board_ids
    |> fetch_current_window(window_days, timezone)
    |> reject_weekend_completions(exclude_weekends?, timezone)
    |> cycle_series_from(window_days, timezone, exclude_weekends?)
  end

  @doc """
  Derives the daily p50 (median) lead-time series (oldest-to-newest) from the
  current trailing window's completed tasks.

  Reuses `cycle_time_daily/3`'s window fetch and bucketing; only the per-day
  statistic differs (lead minutes, measured from `inserted_at`, rather than
  cycle minutes, measured from `claimed_at`).
  """
  @spec lead_time_daily([integer()], pos_integer(), String.t(), boolean()) :: [
          %{date: Date.t(), minutes: non_neg_integer()}
        ]
  def lead_time_daily(board_ids, window_days, timezone, exclude_weekends? \\ false) do
    board_ids
    |> fetch_current_window(window_days, timezone)
    |> reject_weekend_completions(exclude_weekends?, timezone)
    |> lead_series_from(window_days, timezone, exclude_weekends?)
  end

  @doc """
  Derives the daily completion-count series (oldest-to-newest) from the current
  trailing window's completed tasks.
  """
  @spec throughput_daily([integer()], pos_integer(), String.t(), boolean()) :: [non_neg_integer()]
  def throughput_daily(board_ids, window_days, timezone, exclude_weekends? \\ false) do
    board_ids
    |> fetch_current_window(window_days, timezone)
    |> reject_weekend_completions(exclude_weekends?, timezone)
    |> throughput_series_from(window_days, timezone, exclude_weekends?)
  end

  @doc """
  Derives the top-contributor leaderboard (agents before humans, capped at six)
  from the current trailing window's completed tasks.
  """
  @spec leaderboard([integer()], pos_integer(), String.t(), boolean()) :: [map()]
  def leaderboard(board_ids, window_days, timezone, exclude_weekends? \\ false) do
    board_ids
    |> fetch_current_window(window_days, timezone)
    |> reject_weekend_completions(exclude_weekends?, timezone)
    |> leaderboard_from()
  end

  @doc "The zero/empty KPI map, matching `workspace_kpis/1`'s no-boards shape."
  @spec zero_kpis() :: map()
  def zero_kpis do
    %{
      cycle_time_median_minutes: 0,
      cycle_time_delta_pct: 0.0,
      lead_time_p50_minutes: 0,
      lead_time_delta_pct: 0.0,
      throughput_per_day: 0.0,
      throughput_delta_pct: 0.0,
      review_wait_minutes: 0,
      review_wait_delta_pct: 0.0
    }
  end

  @doc "The zero cycle-time series (all-zero minutes) for the trailing window."
  @spec empty_cycle_series(pos_integer(), String.t(), boolean()) :: [
          %{date: Date.t(), minutes: 0}
        ]
  def empty_cycle_series(window_days, timezone, exclude_weekends? \\ false),
    do: zero_day_series(window_days, timezone, exclude_weekends?)

  # Kept as its own name rather than folded into `empty_cycle_series/3`: the two
  # zero paths happen to share a value today, but the façade should not name a
  # *cycle* function on the lead zero-path, and either series may diverge later.
  @doc "The zero lead-time series (all-zero minutes) for the trailing window."
  @spec empty_lead_series(pos_integer(), String.t(), boolean()) :: [%{date: Date.t(), minutes: 0}]
  def empty_lead_series(window_days, timezone, exclude_weekends? \\ false),
    do: zero_day_series(window_days, timezone, exclude_weekends?)

  # Sized off the same day range as the real series rather than `window_days`, so
  # the placeholder and loaded renders agree on length when weekends are excluded
  # (a mismatch would visibly reflow the chart on connect). This is why it needs
  # the timezone the bare-count version never did.
  @doc "The zero throughput series (one zero per day in the trailing window)."
  @spec empty_throughput_series(pos_integer(), String.t(), boolean()) :: [non_neg_integer()]
  def empty_throughput_series(window_days, timezone, exclude_weekends? \\ false) do
    window_days
    |> Windows.day_range(timezone, exclude_weekends?)
    |> Enum.map(fn _date -> 0 end)
  end

  # Splits the shared fetch into the current and previous KPI windows. The two
  # sets overlap on the boundary instant exactly as the original pair of window
  # queries did (current used `completed_at >= current_start`, previous used
  # `completed_at <= current_start`), so a task completed precisely at the
  # boundary lands in both — preserving identical KPI values.
  defp partition_windows(tasks, current_start) do
    current = Enum.filter(tasks, &completed_at_on_or_after?(&1, current_start))
    previous = Enum.filter(tasks, &completed_at_on_or_before?(&1, current_start))
    {current, previous}
  end

  defp completed_at_on_or_after?(%{completed_at: %DateTime{} = dt}, boundary),
    do: DateTime.compare(dt, boundary) != :lt

  defp completed_at_on_or_after?(_, _), do: false

  defp completed_at_on_or_before?(%{completed_at: %DateTime{} = dt}, boundary),
    do: DateTime.compare(dt, boundary) != :gt

  defp completed_at_on_or_before?(_, _), do: false

  defp zero_day_series(window_days, timezone, exclude_weekends?) do
    window_days
    |> Windows.day_range(timezone, exclude_weekends?)
    |> Enum.map(&%{date: &1, minutes: 0})
  end

  # Drops tasks completed on a Saturday or Sunday (in the viewer's timezone) when
  # weekends are excluded. Applied once, immediately after the fetch, so every
  # downstream derivation — KPIs, all three day series, and the leaderboard —
  # sees the same set of tasks. Filtering here rather than per-derivation is what
  # keeps the page internally consistent: a weekend completion cannot be missing
  # from the throughput chart while still moving the KPI strip or the leaderboard.
  defp reject_weekend_completions(tasks, false, _timezone), do: tasks

  defp reject_weekend_completions(tasks, true, timezone) do
    Enum.reject(tasks, fn task ->
      case completed_on_date(task, timezone) do
        %Date{} = date -> Date.day_of_week(date) in [6, 7]
        nil -> false
      end
    end)
  end

  # Derives the daily median cycle-time series from an already-fetched set of
  # completed-task projections. Shared by `cycle_time_daily/4` and
  # `overview_series/4`.
  defp cycle_series_from(tasks, window_days, timezone, exclude_weekends?) do
    daily_minutes_series(
      tasks,
      window_days,
      timezone,
      exclude_weekends?,
      &Durations.median_cycle_minutes(&1, exclude_weekends?)
    )
  end

  # Derives the daily p50 lead-time series from an already-fetched set of
  # completed-task projections. Shared by `lead_time_daily/4` and
  # `overview_series/4`, so the overview path derives it from the window fetch
  # it has already made rather than issuing a second one.
  defp lead_series_from(tasks, window_days, timezone, exclude_weekends?) do
    daily_minutes_series(
      tasks,
      window_days,
      timezone,
      exclude_weekends?,
      &Durations.median_lead_minutes(&1, exclude_weekends?)
    )
  end

  # The shared per-day builder behind both minute-valued series. `minutes_fun`
  # collapses one local day's completed tasks into that day's statistic — the
  # only thing the cycle and lead series differ by. Days with no completions
  # zero-fill, so the result always spans the full window oldest-to-newest
  # (minus the weekend days when they are excluded).
  defp daily_minutes_series(tasks, window_days, timezone, exclude_weekends?, minutes_fun) do
    per_day =
      tasks
      |> Enum.group_by(&completed_on_date(&1, timezone))
      |> Map.new(fn {date, day_tasks} -> {date, minutes_fun.(day_tasks)} end)

    window_days
    |> Windows.day_range(timezone, exclude_weekends?)
    |> Enum.map(&%{date: &1, minutes: Map.get(per_day, &1, 0)})
  end

  # Derives the daily completion-count series from an already-fetched set of
  # completed-task projections. Shared by `throughput_daily/4` and
  # `overview_series/4`.
  defp throughput_series_from(tasks, window_days, timezone, exclude_weekends?) do
    counts = Enum.frequencies_by(tasks, &completed_on_date(&1, timezone))

    window_days
    |> Windows.day_range(timezone, exclude_weekends?)
    |> Enum.map(&Map.get(counts, &1, 0))
  end

  # Derives the top-contributor leaderboard from an already-fetched set of
  # completed-task projections. The completing user's name/email arrive on the
  # projection via the left join, so no `Repo.preload` is needed. Shared by
  # `leaderboard/3` and `overview_series/3`.
  defp leaderboard_from(tasks) do
    agents = agent_leaderboard_rows(tasks)
    humans = human_leaderboard_rows(tasks)

    Enum.take(agents ++ humans, @workspace_agent_leaderboard_limit)
  end

  defp agent_leaderboard_rows(tasks) do
    tasks
    |> Enum.reject(&is_nil(&1.completed_by_agent))
    |> group_leaderboard(:agent, & &1.completed_by_agent)
  end

  defp human_leaderboard_rows(tasks) do
    tasks
    |> Enum.filter(&human_completion?/1)
    |> group_leaderboard(:human, &human_name/1)
  end

  # The one shared completed-task read behind every window-based series. Projects
  # into lightweight maps carrying only the fields the calculations read — no full
  # `%Task{}` structs and no `Repo.preload` — and resolves the completing user's
  # name/email through a left join on `:completed_by` rather than a second query.
  # `reviewed_at` is included because `review_wait_minutes/1` needs it even though
  # it is not one of the fields the task brief enumerated.
  defp fetch(board_ids, %DateTime{} = window_start, %DateTime{} = window_end) do
    Task
    |> join(:inner, [t], c in assoc(t, :column))
    |> join(:left, [t, _c], u in assoc(t, :completed_by))
    |> where([t, c, _u], c.board_id in ^board_ids)
    |> where([t, _c, _u], not is_nil(t.completed_at))
    |> where([t, _c, _u], t.completed_at >= ^window_start)
    |> where([t, _c, _u], t.completed_at <= ^window_end)
    # Goals get a `completed_at` when their last child finishes; exclude them so
    # workspace throughput/cycle-time/leaderboard count only real work, matching
    # every board-level metric query (which all filter `type != :goal`). See D87.
    |> where([t, _c, _u], t.type != ^:goal)
    |> select([t, _c, u], %{
      completed_at: t.completed_at,
      claimed_at: t.claimed_at,
      inserted_at: t.inserted_at,
      needs_review: t.needs_review,
      review_status: t.review_status,
      reviewed_at: t.reviewed_at,
      completed_by_agent: t.completed_by_agent,
      completed_by_id: t.completed_by_id,
      completed_by_name: u.name,
      completed_by_email: u.email
    })
    |> Repo.all()
  end

  # The current trailing window (the last `window_days` local days), shared by the
  # three single-window public reads. `overview_series/3` does not use this — it
  # issues one wider fetch spanning both KPI windows and partitions in memory.
  defp fetch_current_window(board_ids, window_days, timezone) do
    now = DateTime.utc_now()
    window_start = Windows.local_day_start(window_days - 1, timezone)
    fetch(board_ids, window_start, now)
  end

  # `current`/`previous` arrive UNFILTERED. The weekend-completion rule applies
  # only to the count-based measures below, never to the durations: a task
  # claimed Friday and completed Saturday must contribute its business-time
  # cycle here exactly as it does on the board pages (Kanban.Metrics
  # apply_weekend_filter/2 adjusts durations and drops no task). Dropping it
  # would put the workspace KPI and the board KPI back into disagreement — the
  # very mismatch this feature exists to remove.
  defp build_kpis(current, previous, window_days, timezone, exclude_weekends?) do
    cycle_current = Durations.median_cycle_minutes(current, exclude_weekends?)
    cycle_previous = Durations.median_cycle_minutes(previous, exclude_weekends?)

    lead_current = Durations.percentile_lead_minutes(current, 50, exclude_weekends?)
    lead_previous = Durations.percentile_lead_minutes(previous, 50, exclude_weekends?)

    {throughput_current, throughput_previous} =
      throughput_rates(current, previous, window_days, timezone, exclude_weekends?)

    review_current = Durations.median_review_wait_minutes(current, exclude_weekends?)
    review_previous = Durations.median_review_wait_minutes(previous, exclude_weekends?)

    %{
      cycle_time_median_minutes: cycle_current,
      cycle_time_delta_pct: delta_pct(cycle_current, cycle_previous),
      lead_time_p50_minutes: lead_current,
      lead_time_delta_pct: delta_pct(lead_current, lead_previous),
      throughput_per_day: throughput_current,
      throughput_delta_pct: delta_pct(throughput_current, throughput_previous),
      review_wait_minutes: review_current,
      review_wait_delta_pct: delta_pct(review_current, review_previous)
    }
  end

  # The per-day completion rate for each window. Throughput is a COUNT, so this
  # is the one place the weekend-completion rule applies — keeping the KPI equal
  # to the sum of the throughput chart's bars.
  #
  # Each window divides by the days actually counted rather than the raw window
  # length: with weekends excluded, dividing by all 14 calendar days would
  # understate the rate. The two are counted separately because they can hold
  # different numbers of weekdays — a 30- or 90-day window's weekday count varies
  # with where it starts — and sharing one divisor would skew the delta.
  defp throughput_rates(current, previous, window_days, timezone, exclude_weekends?) do
    counted_days = window_days |> Windows.day_range(timezone, exclude_weekends?) |> length()

    previous_counted_days =
      window_days |> Windows.previous_day_range(timezone, exclude_weekends?) |> length()

    counted_current = reject_weekend_completions(current, exclude_weekends?, timezone)
    counted_previous = reject_weekend_completions(previous, exclude_weekends?, timezone)

    {length(counted_current) / counted_days, length(counted_previous) / previous_counted_days}
  end

  # Implements divide-by-zero safety: a 0 previous window collapses to 0.0%.
  defp delta_pct(_current, previous) when previous == 0 or previous == 0.0, do: 0.0

  defp delta_pct(current, previous) when is_number(current) and is_number(previous) do
    (current - previous) / previous * 100.0
  end

  defp human_completion?(%{completed_by_agent: agent}) when is_binary(agent) and agent != "",
    do: false

  defp human_completion?(%{completed_by_id: id}) when is_integer(id), do: true
  defp human_completion?(_), do: false

  defp human_name(%{completed_by_name: name}) when is_binary(name) and name != "", do: name
  defp human_name(%{completed_by_email: email}) when is_binary(email), do: email
  defp human_name(_), do: "?"

  defp group_leaderboard(tasks, kind, name_fun) do
    tasks
    |> Enum.group_by(name_fun)
    |> Enum.map(fn {name, ts} ->
      total = length(ts)
      success = Enum.count(ts, &successful_completion?/1)

      %{
        name: name,
        kind: kind,
        completed: total,
        success_pct: success_pct(success, total)
      }
    end)
    |> Enum.sort_by(& &1.completed, :desc)
  end

  defp successful_completion?(%{needs_review: false}), do: true
  defp successful_completion?(%{review_status: :approved}), do: true
  defp successful_completion?(_), do: false

  defp success_pct(_success, 0), do: 0.0
  defp success_pct(success, total), do: success / total * 100.0

  defp completed_on_date(%{completed_at: %DateTime{} = dt}, timezone),
    do: Timezone.local_date(dt, timezone)

  defp completed_on_date(_, _timezone), do: nil
end
