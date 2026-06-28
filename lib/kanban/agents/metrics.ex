defmodule Kanban.Agents.Metrics do
  @moduledoc """
  Fleet-level aggregate rollups derived from the visible Task set.

  This module holds the read-only aggregate functions for the Agents view —
  the daily header counters, the fleet-health rollup, throughput counts, and
  the throughput time-series with cycle time. They were extracted from
  `Kanban.Agents` (which kept growing past the module-size guideline) so the
  roster/event derivation and the aggregate rollups live behind clear,
  single-responsibility boundaries.

  All functions delegate task fetching, scope filtering, and the shared
  per-task counters back to `Kanban.Agents`, so there is a single source of
  truth for the task set and the counting rules. `Kanban.Agents` re-exposes
  each of these functions through a thin wrapper, so callers continue to use
  the `Kanban.Agents` public API unchanged.

  Every function accepts the same `:scope` (and, for `throughput_trends/1`,
  `:days`) options documented on `Kanban.Agents`.
  """

  alias Kanban.Agents
  alias Kanban.Agents.Event

  # Default number of trailing days in the throughput time-series window when
  # the caller does not pass `:days`. One bucket per UTC date.
  @default_trend_days 14

  @doc """
  Returns aggregate header counters for the Agents view.

  The returned map contains:

    * `:created_today` — count of tasks whose `inserted_at` falls on the
      current local date
    * `:claimed_today` — count of tasks whose `claimed_at` falls on the
      current UTC date
    * `:completed_today` — count of tasks whose `completed_at` falls on
      the current UTC date
    * `:approved_today` — count of tasks whose `reviewed_at` falls on the
      current UTC date with `review_status` `:approved`
    * `:avg_cycle_minutes` — average `time_spent_minutes` across completed
      tasks where the value is set, or `0` when no qualifying tasks exist
  """
  @spec header_stats(keyword()) :: %{
          created_today: non_neg_integer(),
          claimed_today: non_neg_integer(),
          completed_today: non_neg_integer(),
          approved_today: non_neg_integer(),
          avg_cycle_minutes: number()
        }
  def header_stats(opts \\ []), do: header_stats_from(Agents.fetch_tasks(opts))

  @doc """
  Header counters computed from an already-fetched task list. Same shape and
  rules as `header_stats/1`; lets the Agents view share one fetch.
  """
  @spec header_stats_from([Kanban.Tasks.Task.t()], String.t()) :: %{
          created_today: non_neg_integer(),
          claimed_today: non_neg_integer(),
          completed_today: non_neg_integer(),
          approved_today: non_neg_integer(),
          avg_cycle_minutes: number()
        }
  def header_stats_from(tasks, timezone \\ "Etc/UTC") do
    today = local_today(timezone)

    %{
      created_today: count_on_day(tasks, :inserted_at, today, timezone),
      claimed_today: count_on_day(tasks, :claimed_at, today, timezone),
      completed_today: count_on_day(tasks, :completed_at, today, timezone),
      approved_today: count_approved_on(tasks, today, timezone),
      # Scoped to the viewer's local today (the rest of the row is "today" too),
      # unlike the all-time `avg_cycle_minutes/1` the Delivery-trends band uses.
      avg_cycle_minutes: cycle_minutes_on(tasks, today, timezone)
    }
  end

  @doc """
  Returns fleet-health rollup counts for the scoped agent set.

  The returned map carries one count per dimension:

    * `:working` / `:waiting` / `:idle` — number of agents in each derived
      `Agent.status`. These three partition the agent set.
    * `:stuck` — number of agents whose `Agent.stuck` flag is set. Because
      stuck-ness is orthogonal to status (see the "Stuck agents" section of
      `Kanban.Agents`), this is a cross-cutting count that overlaps the status
      buckets — a stalled `:working` agent is counted in both `:working` and
      `:stuck`.

  Counts are derived from `Kanban.Agents.list_agents/1`, so the status and
  stuck rules are shared verbatim (no drift) and the `:scope` board filtering
  is respected. **Dormant agents are excluded** (see the "Dormant agents"
  section of `Kanban.Agents`), so the rollup reflects only live agents. An
  empty (or all-dormant) agent set returns all zeros.
  """
  @spec fleet_health(keyword()) :: %{
          working: non_neg_integer(),
          waiting: non_neg_integer(),
          idle: non_neg_integer(),
          stuck: non_neg_integer()
        }
  def fleet_health(opts \\ []), do: fleet_health_from(Agents.list_agents(opts))

  @doc """
  Fleet-health rollup computed from an already-built agent list. Same shape and
  dormant-exclusion rule as `fleet_health/1`; the caller supplies the roster so
  it is built only once. Pass the full roster (including dormant agents) — this
  function applies the dormant exclusion itself.
  """
  @spec fleet_health_from([Agents.Agent.t()]) :: %{
          working: non_neg_integer(),
          waiting: non_neg_integer(),
          idle: non_neg_integer(),
          stuck: non_neg_integer()
        }
  def fleet_health_from(agents) do
    # Dormant agents are excluded so the rollup reflects only live agents — a
    # long tail of weeks-idle agents must not inflate the idle bucket.
    live_agents = Enum.reject(agents, & &1.dormant)
    by_status = Enum.frequencies_by(live_agents, & &1.status)

    %{
      working: Map.get(by_status, :working, 0),
      waiting: Map.get(by_status, :waiting, 0),
      idle: Map.get(by_status, :idle, 0),
      stuck: Enum.count(live_agents, & &1.stuck)
    }
  end

  @doc """
  Returns fleet-wide throughput counts and an overall success rate.

  Throughput is the number of tasks whose `completed_at` falls within each
  window, counted once per task. The returned map contains:

    * `:completed_today` — completions on the current UTC date
    * `:completed_7d` — completions within the trailing 7-day window
      (today and the six prior days)
    * `:completed_30d` — completions within the trailing 30-day window
    * `:completed_prev_today` / `:completed_prev_7d` / `:completed_prev_30d` —
      completions in the equivalent window immediately *before* each current
      window (yesterday; the 7 days before the current 7-day window; the 30
      days before the current 30-day window), for a like-for-like trend
      comparison
    * `:success_rate` — approved over (approved + rejected) across the
      visible tasks, as a float in `0.0..1.0`; `0.0` when no task has been
      approved or rejected

  Counts are derived directly from the visible Task set — not summed across
  per-agent rollups — so a task touched by two agents is counted once, and
  there is no double-count. `:scope` board filtering is respected. An empty
  task set returns all zeros.
  """
  @spec throughput_and_success(keyword()) :: %{
          completed_today: non_neg_integer(),
          completed_7d: non_neg_integer(),
          completed_30d: non_neg_integer(),
          completed_prev_today: non_neg_integer(),
          completed_prev_7d: non_neg_integer(),
          completed_prev_30d: non_neg_integer(),
          success_rate: float()
        }
  def throughput_and_success(opts \\ []) do
    throughput_and_success_from(Agents.fetch_tasks(opts))
  end

  @doc """
  Throughput counts and success rate computed from an already-fetched task
  list. Same 7-key shape and rules as `throughput_and_success/1`.

  `completed_today` (and the matching `completed_prev_today`) are counted on the
  viewer's local today derived from `timezone`, using the SAME `count_on_day/4`
  computation that powers the header's `completed_today` — so the header stat
  and the Delivery-trends stat can never drift. An unknown/empty `timezone`
  falls back to UTC. The 7d/30d windows keep their UTC-date counting but are
  anchored to the same local `today`.
  """
  @spec throughput_and_success_from([Kanban.Tasks.Task.t()], String.t()) :: %{
          completed_today: non_neg_integer(),
          completed_7d: non_neg_integer(),
          completed_30d: non_neg_integer(),
          completed_prev_today: non_neg_integer(),
          completed_prev_7d: non_neg_integer(),
          completed_prev_30d: non_neg_integer(),
          success_rate: float()
        }
  def throughput_and_success_from(tasks, timezone \\ "Etc/UTC") do
    today = local_today(timezone)

    %{
      completed_today: count_on_day(tasks, :completed_at, today, timezone),
      completed_7d: Agents.count_completed_within(tasks, today, 7, timezone),
      completed_30d: Agents.count_completed_within(tasks, today, 30, timezone),
      # Deliberately the shared local-day count (mirroring completed_today, so the
      # today/prev-today delta stays parity-locked with the header), NOT the
      # trailing-window subtraction the prev_7d/prev_30d keys below use.
      completed_prev_today: count_on_day(tasks, :completed_at, Date.add(today, -1), timezone),
      completed_prev_7d: completed_in_prior_window(tasks, today, 7, timezone),
      completed_prev_30d: completed_in_prior_window(tasks, today, 30, timezone),
      success_rate: Agents.success_rate(tasks)
    }
  end

  # Completions in the window of `days` immediately BEFORE the current trailing
  # `days`-day window — the last `2 * days` days minus the most recent `days`.
  # Reuses Agents.count_completed_within so the prior and current windows share
  # the same local-date counting rule (in `timezone`), enabling a like-for-like
  # comparison anchored to the viewer's local day.
  defp completed_in_prior_window(tasks, today, days, timezone) do
    Agents.count_completed_within(tasks, today, days * 2, timezone) -
      Agents.count_completed_within(tasks, today, days, timezone)
  end

  @doc """
  Returns a per-day throughput time-series and an aggregate cycle-time metric.

  Accepts an optional `:days` window (default `#{@default_trend_days}`). The
  returned map contains:

    * `:series` — one bucket per day across the trailing window, oldest
      first, each a `%{date: Date.t(), count: non_neg_integer()}` where
      `count` is the number of tasks completed on that day. The series
      always has exactly `:days` buckets (zero-filled), so a window with no
      activity yields all-zero counts rather than a short list. A non-positive
      `:days` yields an empty series.
    * `:avg_cycle_minutes` — the average `time_spent_minutes` across completed
      tasks with a recorded value, or `0.0` when none qualify. This reuses the
      module's canonical cycle-time definition (`time_spent_minutes`, the same
      value surfaced on `#{inspect(Event)}.cycle_time_minutes`) — no new
      definition is introduced.

  This keyword entry has no viewer timezone, so its buckets are keyed by the
  UTC date of `completed_at`. For viewer-local bucketing — which keeps the
  chart's most-recent bar in agreement with the local "Completed today" stat —
  use `throughput_trends_from/3` with a timezone. `:scope` board filtering is
  respected.
  """
  @spec throughput_trends(keyword()) :: %{
          series: [%{date: Date.t(), count: non_neg_integer()}],
          avg_cycle_minutes: number()
        }
  def throughput_trends(opts \\ []) do
    throughput_trends_from(
      Agents.fetch_tasks(opts),
      Keyword.get(opts, :days, @default_trend_days)
    )
  end

  @doc """
  Per-day throughput series and cycle-time metric computed from an
  already-fetched task list over a `days`-day window. Same shape as
  `throughput_trends/1`. Callers that want the default window should pass
  `default_trend_days/0`.

  `timezone` keys each bucket on the viewer's local calendar day (via the same
  `local_today/1` + `count_on_day/4` machinery the header and Delivery-trends
  "Completed today" stats use), so the most-recent bar agrees with that stat.
  An unknown/empty `timezone` falls back to UTC bucketing without raising.
  """
  @spec throughput_trends_from([Kanban.Tasks.Task.t()], integer(), String.t()) :: %{
          series: [%{date: Date.t(), count: non_neg_integer()}],
          avg_cycle_minutes: number()
        }
  def throughput_trends_from(tasks, days \\ @default_trend_days, timezone \\ "Etc/UTC") do
    today = local_today(timezone)

    %{
      series: throughput_buckets(tasks, today, days, timezone),
      avg_cycle_minutes: avg_cycle_minutes(tasks)
    }
  end

  @doc """
  The default throughput-trends window (in days) used when no `:days` option is
  given. Exposed so callers of `throughput_trends_from/2` can request the same
  default window the keyword API uses.
  """
  @spec default_trend_days() :: pos_integer()
  def default_trend_days, do: @default_trend_days

  # --- private helpers -------------------------------------------------------

  defp count_on_day(tasks, field, date, timezone) do
    Enum.count(tasks, fn task ->
      case Map.get(task, field) do
        %DateTime{} = dt ->
          local_date(dt, timezone) == date

        # `inserted_at`/`updated_at` come from bare `timestamps()` and are
        # naive UTC, unlike the `:utc_datetime` claim/complete/review fields.
        # Treat them as UTC so the local-day comparison matches the others.
        %NaiveDateTime{} = ndt ->
          local_date(DateTime.from_naive!(ndt, "Etc/UTC"), timezone) == date

        _ ->
          false
      end
    end)
  end

  defp count_approved_on(tasks, date, timezone) do
    Enum.count(tasks, fn task ->
      task.review_status == :approved and match?(%DateTime{}, task.reviewed_at) and
        local_date(task.reviewed_at, timezone) == date
    end)
  end

  # All-time average `time_spent_minutes` across completed tasks. Used by the
  # Delivery-trends band (`throughput_trends_from/2`); NOT the header — see
  # `cycle_minutes_on/3` for the today-scoped header figure.
  defp avg_cycle_minutes(tasks) do
    minutes =
      tasks
      |> Enum.filter(&(not is_nil(&1.completed_at) and is_integer(&1.time_spent_minutes)))
      |> Enum.map(& &1.time_spent_minutes)

    average(minutes)
  end

  # Average `time_spent_minutes` across tasks completed on the viewer's local
  # `date`. Empty set yields 0.0 (the header renders an em-dash), never an
  # ArithmeticError.
  defp cycle_minutes_on(tasks, date, timezone) do
    tasks
    |> Enum.filter(fn task ->
      match?(%DateTime{}, task.completed_at) and is_integer(task.time_spent_minutes) and
        local_date(task.completed_at, timezone) == date
    end)
    |> Enum.map(& &1.time_spent_minutes)
    |> average()
  end

  defp average([]), do: 0.0
  defp average(list), do: Enum.sum(list) / length(list)

  # Local-day helpers live on `Kanban.Agents` as the single source of truth so
  # the header, Delivery-trends, and roster counts all anchor to the same local
  # "today"/date boundary. These thin wrappers keep the call sites terse.
  defp local_today(timezone), do: Agents.local_today(timezone)
  defp local_date(dt, timezone), do: Agents.local_date(dt, timezone)

  # One zero-filled throughput bucket per day across the trailing window, oldest
  # first. Counts each day on the viewer's local calendar via count_on_day/4 (the
  # same shared local-day count the header/Delivery-trends "Completed today" stats
  # use), so the most-recent bar agrees with that stat; an unknown timezone falls
  # back to UTC. A non-positive window yields an empty series.
  defp throughput_buckets(_tasks, _today, days, _timezone) when days < 1, do: []

  defp throughput_buckets(tasks, today, days, timezone) do
    earliest = Date.add(today, -(days - 1))

    earliest
    |> Date.range(today)
    |> Enum.map(fn date ->
      %{date: date, count: count_on_day(tasks, :completed_at, date, timezone)}
    end)
  end
end
