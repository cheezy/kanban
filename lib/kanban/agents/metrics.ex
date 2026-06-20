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
  @spec header_stats_from([Kanban.Tasks.Task.t()]) :: %{
          claimed_today: non_neg_integer(),
          completed_today: non_neg_integer(),
          approved_today: non_neg_integer(),
          avg_cycle_minutes: number()
        }
  def header_stats_from(tasks) do
    today = Date.utc_today()

    %{
      claimed_today: count_on_day(tasks, :claimed_at, today),
      completed_today: count_on_day(tasks, :completed_at, today),
      approved_today: count_approved_on(tasks, today),
      avg_cycle_minutes: avg_cycle_minutes(tasks)
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
  """
  @spec throughput_and_success_from([Kanban.Tasks.Task.t()]) :: %{
          completed_today: non_neg_integer(),
          completed_7d: non_neg_integer(),
          completed_30d: non_neg_integer(),
          completed_prev_today: non_neg_integer(),
          completed_prev_7d: non_neg_integer(),
          completed_prev_30d: non_neg_integer(),
          success_rate: float()
        }
  def throughput_and_success_from(tasks) do
    today = Date.utc_today()

    %{
      completed_today: Agents.count_completed_on_day(tasks, today),
      completed_7d: Agents.count_completed_within(tasks, today, 7),
      completed_30d: Agents.count_completed_within(tasks, today, 30),
      completed_prev_today: completed_in_prior_window(tasks, today, 1),
      completed_prev_7d: completed_in_prior_window(tasks, today, 7),
      completed_prev_30d: completed_in_prior_window(tasks, today, 30),
      success_rate: Agents.success_rate(tasks)
    }
  end

  # Completions in the window of `days` immediately BEFORE the current trailing
  # `days`-day window — the last `2 * days` days minus the most recent `days`.
  # Reuses Agents.count_completed_within so the prior and current windows share
  # the same UTC-date counting rule, enabling a like-for-like comparison.
  defp completed_in_prior_window(tasks, today, days) do
    Agents.count_completed_within(tasks, today, days * 2) -
      Agents.count_completed_within(tasks, today, days)
  end

  @doc """
  Returns a per-day throughput time-series and an aggregate cycle-time metric.

  Accepts an optional `:days` window (default `#{@default_trend_days}`). The
  returned map contains:

    * `:series` — one bucket per day across the trailing window, oldest
      first, each a `%{date: Date.t(), count: non_neg_integer()}` where
      `count` is the number of tasks completed on that UTC date. The series
      always has exactly `:days` buckets (zero-filled), so a window with no
      activity yields all-zero counts rather than a short list. A non-positive
      `:days` yields an empty series.
    * `:avg_cycle_minutes` — the average `time_spent_minutes` across completed
      tasks with a recorded value, or `0.0` when none qualify. This reuses the
      module's canonical cycle-time definition (`time_spent_minutes`, the same
      value surfaced on `#{inspect(Event)}.cycle_time_minutes`) — no new
      definition is introduced.

  Buckets are keyed by `DateTime.to_date/1` of `completed_at`, which is stored
  in UTC, so bucketing is deterministic and time-zone independent. `:scope`
  board filtering is respected.
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
  already-fetched task list over a `days`-day window. Same shape and rules as
  `throughput_trends/1`. Callers that want the default window should pass
  `default_trend_days/0`.
  """
  @spec throughput_trends_from([Kanban.Tasks.Task.t()], integer()) :: %{
          series: [%{date: Date.t(), count: non_neg_integer()}],
          avg_cycle_minutes: number()
        }
  def throughput_trends_from(tasks, days \\ @default_trend_days) do
    today = Date.utc_today()

    %{
      series: throughput_buckets(tasks, today, days),
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

  defp count_on_day(tasks, field, date) do
    Enum.count(tasks, fn task ->
      case Map.get(task, field) do
        nil -> false
        %DateTime{} = dt -> DateTime.to_date(dt) == date
      end
    end)
  end

  defp count_approved_on(tasks, date) do
    Enum.count(tasks, fn task ->
      task.review_status == :approved and not is_nil(task.reviewed_at) and
        DateTime.to_date(task.reviewed_at) == date
    end)
  end

  defp avg_cycle_minutes(tasks) do
    minutes =
      tasks
      |> Enum.filter(&(not is_nil(&1.completed_at) and is_integer(&1.time_spent_minutes)))
      |> Enum.map(& &1.time_spent_minutes)

    case minutes do
      [] -> 0.0
      list -> Enum.sum(list) / length(list)
    end
  end

  # One zero-filled throughput bucket per UTC date across the trailing window,
  # oldest first. Reuses Agents.count_completed_on_day/2 so bucketing matches
  # the rest of the context (UTC date of completed_at, time-zone independent).
  # A non-positive window yields an empty series.
  defp throughput_buckets(_tasks, _today, days) when days < 1, do: []

  defp throughput_buckets(tasks, today, days) do
    earliest = Date.add(today, -(days - 1))

    earliest
    |> Date.range(today)
    |> Enum.map(fn date -> %{date: date, count: Agents.count_completed_on_day(tasks, date)} end)
  end
end
