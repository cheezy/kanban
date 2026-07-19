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
  `window_days`, and `timezone`.
  """

  import Ecto.Query, warn: false

  alias Kanban.Metrics.Calculations
  alias Kanban.Metrics.Workspace.Windows
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias Kanban.Timezone

  @workspace_agent_leaderboard_limit 6

  @doc """
  Derives the four completed-task payloads (`:kpis`, `:cycle_series`,
  `:throughput_series`, `:leaderboard`) from a single window-spanning fetch,
  partitioned in memory into the current and previous KPI windows. This is the
  read-collapsing path behind `overview/1`: one projected fetch covering
  `previous_start..now` replaces the five the individual reads would issue.
  """
  @spec overview_series([integer()], pos_integer(), String.t()) :: %{
          kpis: map(),
          cycle_series: [%{date: Date.t(), minutes: non_neg_integer()}],
          throughput_series: [non_neg_integer()],
          leaderboard: [map()]
        }
  def overview_series(board_ids, window_days, timezone) do
    now = DateTime.utc_now()
    current_start = Windows.local_day_start(window_days - 1, timezone)
    previous_start = Windows.local_day_start(2 * window_days - 1, timezone)

    {current, previous} =
      board_ids
      |> fetch(previous_start, now)
      |> partition_windows(current_start)

    %{
      kpis: build_kpis(current, previous, window_days),
      cycle_series: cycle_series_from(current, window_days, timezone),
      throughput_series: throughput_series_from(current, window_days, timezone),
      leaderboard: leaderboard_from(current)
    }
  end

  @doc """
  Derives the workspace KPI strip for the trailing window with delta percentages
  vs the previous equal-length window. Issues two window fetches (current and
  previous), mirroring `workspace_kpis/1`'s standalone read.
  """
  @spec kpis([integer()], pos_integer(), String.t()) :: map()
  def kpis(board_ids, window_days, timezone) do
    now = DateTime.utc_now()
    current_start = Windows.local_day_start(window_days - 1, timezone)
    previous_start = Windows.local_day_start(2 * window_days - 1, timezone)

    current = fetch(board_ids, current_start, now)
    previous = fetch(board_ids, previous_start, current_start)

    build_kpis(current, previous, window_days)
  end

  @doc """
  Derives the daily median cycle-time series (oldest-to-newest) from the current
  trailing window's completed tasks.
  """
  @spec cycle_time_daily([integer()], pos_integer(), String.t()) :: [
          %{date: Date.t(), minutes: non_neg_integer()}
        ]
  def cycle_time_daily(board_ids, window_days, timezone) do
    board_ids
    |> fetch_current_window(window_days, timezone)
    |> cycle_series_from(window_days, timezone)
  end

  @doc """
  Derives the daily p50 (median) lead-time series (oldest-to-newest) from the
  current trailing window's completed tasks.

  Reuses `cycle_time_daily/3`'s window fetch and bucketing; only the per-day
  statistic differs (lead minutes, measured from `inserted_at`, rather than
  cycle minutes, measured from `claimed_at`).
  """
  @spec lead_time_daily([integer()], pos_integer(), String.t()) :: [
          %{date: Date.t(), minutes: non_neg_integer()}
        ]
  def lead_time_daily(board_ids, window_days, timezone) do
    board_ids
    |> fetch_current_window(window_days, timezone)
    |> daily_minutes_series(window_days, timezone, &median_lead_minutes/1)
  end

  @doc """
  Derives the daily completion-count series (oldest-to-newest) from the current
  trailing window's completed tasks.
  """
  @spec throughput_daily([integer()], pos_integer(), String.t()) :: [non_neg_integer()]
  def throughput_daily(board_ids, window_days, timezone) do
    board_ids
    |> fetch_current_window(window_days, timezone)
    |> throughput_series_from(window_days, timezone)
  end

  @doc """
  Derives the top-contributor leaderboard (agents before humans, capped at six)
  from the current trailing window's completed tasks.
  """
  @spec leaderboard([integer()], pos_integer(), String.t()) :: [map()]
  def leaderboard(board_ids, window_days, timezone) do
    board_ids
    |> fetch_current_window(window_days, timezone)
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
  @spec empty_cycle_series(pos_integer(), String.t()) :: [%{date: Date.t(), minutes: 0}]
  def empty_cycle_series(window_days, timezone), do: zero_day_series(window_days, timezone)

  # Kept as its own name rather than folded into `empty_cycle_series/2`: the two
  # zero paths happen to share a value today, but the façade should not name a
  # *cycle* function on the lead zero-path, and either series may diverge later.
  @doc "The zero lead-time series (all-zero minutes) for the trailing window."
  @spec empty_lead_series(pos_integer(), String.t()) :: [%{date: Date.t(), minutes: 0}]
  def empty_lead_series(window_days, timezone), do: zero_day_series(window_days, timezone)

  @doc "The zero throughput series (a `window_days`-long list of zeros)."
  @spec empty_throughput_series(pos_integer()) :: [non_neg_integer()]
  def empty_throughput_series(window_days), do: List.duplicate(0, window_days)

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

  defp zero_day_series(window_days, timezone) do
    window_days
    |> Windows.day_range(timezone)
    |> Enum.map(&%{date: &1, minutes: 0})
  end

  # Derives the daily median cycle-time series from an already-fetched set of
  # completed-task projections. Shared by `cycle_time_daily/3` and
  # `overview_series/3`.
  defp cycle_series_from(tasks, window_days, timezone) do
    daily_minutes_series(tasks, window_days, timezone, &median_cycle_minutes/1)
  end

  # The shared per-day builder behind both minute-valued series. `minutes_fun`
  # collapses one local day's completed tasks into that day's statistic — the
  # only thing the cycle and lead series differ by. Days with no completions
  # zero-fill, so the result always spans the full window oldest-to-newest.
  defp daily_minutes_series(tasks, window_days, timezone, minutes_fun) do
    per_day =
      tasks
      |> Enum.group_by(&completed_on_date(&1, timezone))
      |> Map.new(fn {date, day_tasks} -> {date, minutes_fun.(day_tasks)} end)

    window_days
    |> Windows.day_range(timezone)
    |> Enum.map(&%{date: &1, minutes: Map.get(per_day, &1, 0)})
  end

  # Derives the daily completion-count series from an already-fetched set of
  # completed-task projections. Shared by `throughput_daily/3` and
  # `overview_series/3`.
  defp throughput_series_from(tasks, window_days, timezone) do
    counts = Enum.frequencies_by(tasks, &completed_on_date(&1, timezone))

    window_days
    |> Windows.day_range(timezone)
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

  defp build_kpis(current, previous, window_days) do
    cycle_current = median_cycle_minutes(current)
    cycle_previous = median_cycle_minutes(previous)

    lead_current = percentile_lead_minutes(current, 50)
    lead_previous = percentile_lead_minutes(previous, 50)

    throughput_current = length(current) / window_days
    throughput_previous = length(previous) / window_days

    review_current = median_review_wait_minutes(current)
    review_previous = median_review_wait_minutes(previous)

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

  # Implements divide-by-zero safety: a 0 previous window collapses to 0.0%.
  defp delta_pct(_current, previous) when previous == 0 or previous == 0.0, do: 0.0

  defp delta_pct(current, previous) when is_number(current) and is_number(previous) do
    (current - previous) / previous * 100.0
  end

  defp median_cycle_minutes(tasks) do
    tasks
    |> Enum.map(&cycle_minutes/1)
    |> Enum.reject(&is_nil/1)
    |> Calculations.median()
    |> round_or_zero()
  end

  # The per-day lead statistic. p50 (the median) is deliberate: it matches the
  # KPI strip's lead-time cell and makes the lead and cycle series — which both
  # report a median — directly comparable.
  defp median_lead_minutes(tasks), do: percentile_lead_minutes(tasks, 50)

  defp percentile_lead_minutes(tasks, p) do
    tasks
    |> Enum.map(&lead_minutes/1)
    |> Enum.reject(&is_nil/1)
    |> Calculations.percentile(p)
    |> round_or_zero()
  end

  defp median_review_wait_minutes(tasks) do
    tasks
    |> Enum.map(&review_wait_minutes/1)
    |> Enum.reject(&is_nil/1)
    |> Calculations.median()
    |> round_or_zero()
  end

  defp cycle_minutes(%{claimed_at: %DateTime{} = c, completed_at: %DateTime{} = d}) do
    DateTime.diff(d, c, :second) |> max(0) |> div(60)
  end

  defp cycle_minutes(_), do: nil

  defp lead_minutes(%{inserted_at: %NaiveDateTime{} = i, completed_at: %DateTime{} = d}) do
    inserted = DateTime.from_naive!(i, "Etc/UTC")
    DateTime.diff(d, inserted, :second) |> max(0) |> div(60)
  end

  defp lead_minutes(_), do: nil

  defp review_wait_minutes(%{
         needs_review: true,
         completed_at: %DateTime{} = c,
         reviewed_at: %DateTime{} = r
       }) do
    DateTime.diff(r, c, :second) |> max(0) |> div(60)
  end

  defp review_wait_minutes(_), do: nil

  defp round_or_zero(nil), do: 0
  defp round_or_zero(value) when is_number(value), do: round(value)

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
