defmodule Kanban.Metrics do
  @moduledoc """
  The Metrics context for querying and aggregating task data for lean metrics calculations.

  Provides functions to calculate throughput, cycle time, lead time, and wait time statistics
  for kanban boards.

  ## Workspace-level functions (W579)

  Five workspace-scoped functions back the `/metrics` page and aggregate
  across every board the scoped user can access:

    * `workspace_kpis/1` — KPI strip with delta-vs-previous-14-day percentages
    * `cycle_time_daily/1` — 14 daily medians split agent / human
    * `throughput_daily/1` — 14 daily completion counts
    * `agent_leaderboard/1` — top 6 contributors (agents before humans)
    * `cumulative_flow/1` — 14 daily snapshots across 5 derived states

  All five accept `opts` with `:scope` and route through
  `Kanban.Boards.list_boards(scope.user)` to derive the visible board id
  set. A `nil` scope or a scope with `nil` user returns the empty/zero
  shape — never raises.

  ### Cumulative-flow approximation

  No daily snapshot table exists. Each per-day snapshot is reconstructed
  by classifying every visible task by its timestamp state at end-of-day:

  | Bucket    | Rule (at end-of-day D) |
  |-----------|-------------------------|
  | `:backlog`  | `inserted_at <= D` and `claimed_at IS NULL` |
  | `:ready`    | always 0 (no schema distinction between :open and "ready"; reserved for a future snapshot table) |
  | `:doing`    | `claimed_at <= D` and (`completed_at` is `nil` or `> D`) |
  | `:review`   | `completed_at <= D`, `needs_review`, and (`reviewed_at` is `nil` or `> D`) |
  | `:done`     | `reviewed_at <= D` OR (`completed_at <= D` and not `needs_review`) |

  Archived tasks (`archived_at <= D`) are excluded from every bucket.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Metrics.Calculations
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskHistory

  @doc """
  Returns a dashboard summary with all key metrics for a board.

  Combines throughput, cycle time, lead time, and wait time stats into a single response.

  ## Options

  * `:time_range` - One of `:today`, `:last_7_days`, `:last_30_days`, `:last_90_days`, `:all_time` (default: `:last_30_days`)
  * `:agent_name` - Filter by agent name (e.g., "Claude Sonnet 4.5")
  * `:exclude_weekends` - Whether to exclude weekend days from calculations (default: `false`)

  ## Examples

      iex> get_dashboard_summary(board_id)
      {:ok, %{throughput: [...], cycle_time: %{...}, lead_time: %{...}, wait_time: %{...}}}

      iex> get_dashboard_summary(board_id, time_range: :last_7_days, agent_name: "Claude Sonnet 4.5")
      {:ok, %{...}}

  """
  def get_dashboard_summary(board_id, opts \\ []) do
    with {:ok, throughput} <- get_throughput(board_id, opts) do
      build_remaining_dashboard_summary(board_id, opts, throughput)
    end
  end

  defp build_remaining_dashboard_summary(board_id, opts, throughput) do
    with {:ok, cycle_time} <- get_cycle_time_stats(board_id, opts),
         {:ok, lead_time} <- get_lead_time_stats(board_id, opts),
         {:ok, wait_time} <- get_wait_time_stats(board_id, opts) do
      {:ok,
       %{
         throughput: throughput,
         cycle_time: cycle_time,
         lead_time: lead_time,
         wait_time: wait_time
       }}
    end
  end

  @doc """
  Returns a list of unique agent names from completed or created tasks for a board.

  Useful for populating agent filter dropdowns.

  ## Examples

      iex> get_agents(board_id)
      {:ok, ["Claude Sonnet 4.5", "Claude Opus 3", "GPT-4"]}

  """
  def get_agents(board_id) do
    if board_ai_optimized?(board_id) do
      query =
        from t in Task,
          join: c in assoc(t, :column),
          where: c.board_id == ^board_id,
          where: not is_nil(t.completed_by_agent) or not is_nil(t.created_by_agent),
          select: fragment("? as agent", t.completed_by_agent),
          union:
            ^from(t in Task,
              join: c in assoc(t, :column),
              where: c.board_id == ^board_id,
              where: not is_nil(t.created_by_agent),
              select: fragment("? as agent", t.created_by_agent)
            )

      agents =
        query
        |> Repo.all()
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()

      {:ok, agents}
    else
      {:ok, []}
    end
  end

  @doc """
  Returns throughput data (completed tasks per day) for a board.

  ## Options

  * `:time_range` - One of `:today`, `:last_7_days`, `:last_30_days`, `:last_90_days`, `:all_time` (default: `:last_30_days`)
  * `:agent_name` - Filter by agent name
  * `:exclude_weekends` - Whether to exclude weekend days (default: `false`)

  ## Examples

      iex> get_throughput(board_id)
      {:ok, [%{date: ~D[2026-02-05], count: 5}, ...]}

      iex> get_throughput(board_id, time_range: :last_7_days)
      {:ok, [...]}

  """
  def get_throughput(board_id, opts \\ []) do
    time_range = Keyword.get(opts, :time_range, :last_30_days)
    agent_name = Keyword.get(opts, :agent_name)
    exclude_weekends = Keyword.get(opts, :exclude_weekends, false)

    start_date = get_start_date(time_range)
    results = throughput_query(board_id, start_date, agent_name) |> Repo.all()

    {:ok, maybe_reject_weekends(results, exclude_weekends)}
  end

  defp throughput_query(board_id, start_date, agent_name) do
    Task
    |> join(:inner, [t], c in assoc(t, :column))
    |> where([t, c], c.board_id == ^board_id)
    |> where([t], not is_nil(t.completed_at))
    |> where([t], t.completed_at >= ^start_date)
    |> where([t], t.type != ^:goal)
    |> maybe_filter_by_agent(agent_name)
    |> group_by([t], fragment("DATE(?)", t.completed_at))
    |> select([t], %{
      date: fragment("DATE(?)", t.completed_at),
      count: count(t.id)
    })
    |> order_by([t], fragment("DATE(?)", t.completed_at))
  end

  defp maybe_reject_weekends(results, false), do: results

  defp maybe_reject_weekends(results, true) do
    Enum.reject(results, fn %{date: date} -> Date.day_of_week(date) in [6, 7] end)
  end

  @doc """
  Returns cycle time statistics for a board.

  Cycle time is measured from `claimed_at` to `completed_at` (time actively working on tasks).

  ## Options

  * `:time_range` - One of `:today`, `:last_7_days`, `:last_30_days`, `:last_90_days`, `:all_time` (default: `:last_30_days`)
  * `:agent_name` - Filter by agent name
  * `:exclude_weekends` - Whether to exclude weekends from calculation (default: `false`)

  ## Examples

      iex> get_cycle_time_stats(board_id)
      {:ok, %{average_hours: 24.5, median_hours: 20.0, min_hours: 2.0, max_hours: 72.0, count: 50}}

  """
  def get_cycle_time_stats(board_id, opts \\ []) do
    time_range = Keyword.get(opts, :time_range, :last_30_days)
    exclude_weekends = Keyword.get(opts, :exclude_weekends, false)
    start_date = get_start_date(time_range)

    if board_ai_optimized?(board_id) do
      agent_name = Keyword.get(opts, :agent_name)
      get_cycle_time_stats_ai(board_id, start_date, agent_name, exclude_weekends)
    else
      get_cycle_time_stats_from_history(board_id, start_date, exclude_weekends)
    end
  end

  defp get_cycle_time_stats_ai(board_id, start_date, agent_name, exclude_weekends) do
    query =
      Task
      |> join(:inner, [t], c in assoc(t, :column))
      |> where([t, c], c.board_id == ^board_id)
      |> where([t], not is_nil(t.completed_at))
      |> where([t], not is_nil(t.claimed_at))
      |> where([t], t.completed_at >= ^start_date)
      |> where([t], t.type != ^:goal)
      |> maybe_filter_by_agent(agent_name)
      |> select([t], %{
        cycle_time_seconds:
          fragment(
            "EXTRACT(EPOCH FROM (? - ?))",
            t.completed_at,
            t.claimed_at
          ),
        completed_at: t.completed_at,
        claimed_at: t.claimed_at
      })

    results = Repo.all(query)

    filtered_results =
      if exclude_weekends do
        Enum.map(results, fn result ->
          adjusted_seconds = calculate_business_time(result.claimed_at, result.completed_at)
          %{result | cycle_time_seconds: adjusted_seconds}
        end)
      else
        results
      end

    calculate_time_stats(filtered_results)
  end

  defp get_cycle_time_stats_from_history(board_id, start_date, exclude_weekends) do
    first_move_subquery =
      from th in TaskHistory,
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
      |> select([t, _c, fm], %{
        cycle_time_seconds:
          fragment("EXTRACT(EPOCH FROM (? - ?))", t.completed_at, fm.started_at),
        completed_at: t.completed_at,
        claimed_at: fm.started_at
      })

    results = Repo.all(query)

    filtered_results =
      if exclude_weekends do
        Enum.map(results, fn result ->
          claimed_at = normalize_to_datetime(result.claimed_at)
          adjusted_seconds = calculate_business_time(claimed_at, result.completed_at)
          %{result | cycle_time_seconds: adjusted_seconds}
        end)
      else
        results
      end

    calculate_time_stats(filtered_results)
  end

  @doc """
  Returns lead time statistics for a board.

  Lead time is measured from task creation (`inserted_at`) to completion (`completed_at`).

  ## Options

  * `:time_range` - One of `:today`, `:last_7_days`, `:last_30_days`, `:last_90_days`, `:all_time` (default: `:last_30_days`)
  * `:agent_name` - Filter by agent name
  * `:exclude_weekends` - Whether to exclude weekends from calculation (default: `false`)

  ## Examples

      iex> get_lead_time_stats(board_id)
      {:ok, %{average_hours: 48.5, median_hours: 40.0, min_hours: 12.0, max_hours: 120.0, count: 50}}

  """
  def get_lead_time_stats(board_id, opts \\ []) do
    time_range = Keyword.get(opts, :time_range, :last_30_days)
    agent_name = Keyword.get(opts, :agent_name)
    exclude_weekends = Keyword.get(opts, :exclude_weekends, false)

    start_date = get_start_date(time_range)

    query =
      Task
      |> join(:inner, [t], c in assoc(t, :column))
      |> where([t, c], c.board_id == ^board_id)
      |> where([t], not is_nil(t.completed_at))
      |> where([t], t.completed_at >= ^start_date)
      |> where([t], t.type != ^:goal)
      |> maybe_filter_by_agent(agent_name)
      |> select([t], %{
        lead_time_seconds:
          fragment(
            "EXTRACT(EPOCH FROM (? - ?))",
            t.completed_at,
            t.inserted_at
          ),
        inserted_at: t.inserted_at,
        end_time: t.completed_at
      })

    results = Repo.all(query)

    filtered_results =
      if exclude_weekends do
        Enum.map(results, fn result ->
          adjusted_seconds = calculate_business_time(result.inserted_at, result.end_time)
          %{result | lead_time_seconds: adjusted_seconds}
        end)
      else
        results
      end

    calculate_time_stats(filtered_results)
  end

  @doc """
  Returns wait time statistics for a board.

  Wait time is separated into:
  * Review wait time - Time from `completed_at` to `reviewed_at`
  * Backlog wait time - Time from creation to being claimed (if applicable)

  ## Options

  * `:time_range` - One of `:today`, `:last_7_days`, `:last_30_days`, `:last_90_days`, `:all_time` (default: `:last_30_days`)
  * `:agent_name` - Filter by agent name
  * `:exclude_weekends` - Whether to exclude weekends from calculation (default: `false`)

  ## Examples

      iex> get_wait_time_stats(board_id)
      {:ok, %{
        review_wait: %{average_hours: 12.0, ...},
        backlog_wait: %{average_hours: 18.0, ...}
      }}

  """
  def get_wait_time_stats(board_id, opts \\ []) do
    time_range = Keyword.get(opts, :time_range, :last_30_days)
    exclude_weekends = Keyword.get(opts, :exclude_weekends, false)
    start_date = get_start_date(time_range)

    if board_ai_optimized?(board_id) do
      agent_name = Keyword.get(opts, :agent_name)
      compute_ai_wait_time_stats(board_id, start_date, agent_name, exclude_weekends)
    else
      get_wait_time_stats_from_history(board_id, start_date, exclude_weekends)
    end
  end

  defp compute_ai_wait_time_stats(board_id, start_date, agent_name, exclude_weekends) do
    review_results =
      fetch_review_wait_times(board_id, start_date, agent_name, exclude_weekends)

    backlog_results =
      fetch_backlog_wait_times(board_id, start_date, agent_name, exclude_weekends)

    with {:ok, review_stats} <- calculate_wait_time_stats(review_results),
         {:ok, backlog_stats} <- calculate_wait_time_stats(backlog_results) do
      {:ok,
       %{
         review_wait: review_stats,
         backlog_wait: backlog_stats
       }}
    end
  end

  defp fetch_review_wait_times(board_id, start_date, agent_name, exclude_weekends) do
    query =
      Task
      |> join(:inner, [t], c in assoc(t, :column))
      |> where([t, c], c.board_id == ^board_id)
      |> where([t], not is_nil(t.completed_at))
      |> where([t], not is_nil(t.reviewed_at))
      |> where([t], t.completed_at >= ^start_date)
      |> where([t], t.type != ^:goal)
      |> maybe_filter_by_agent(agent_name)
      |> select([t], %{
        wait_time_seconds:
          fragment(
            "GREATEST(0, EXTRACT(EPOCH FROM (? - ?)))",
            t.reviewed_at,
            t.completed_at
          ),
        start_time: t.completed_at,
        end_time: t.reviewed_at
      })

    query
    |> Repo.all()
    |> apply_weekend_filter(exclude_weekends)
  end

  defp fetch_backlog_wait_times(board_id, start_date, agent_name, exclude_weekends) do
    query =
      Task
      |> join(:inner, [t], c in assoc(t, :column))
      |> where([t, c], c.board_id == ^board_id)
      |> where([t], not is_nil(t.claimed_at))
      |> where([t], t.inserted_at >= ^start_date)
      |> where([t], t.type != ^:goal)
      |> maybe_filter_by_agent(agent_name)
      |> select([t], %{
        wait_time_seconds:
          fragment(
            "GREATEST(0, EXTRACT(EPOCH FROM (? - ?)))",
            t.claimed_at,
            t.inserted_at
          ),
        start_time: t.inserted_at,
        end_time: t.claimed_at
      })

    query
    |> Repo.all()
    |> apply_weekend_filter(exclude_weekends)
  end

  defp apply_weekend_filter(results, false), do: results

  defp apply_weekend_filter(results, true) do
    Enum.map(results, fn result ->
      adjusted_seconds = calculate_business_time(result.start_time, result.end_time)
      %{result | wait_time_seconds: adjusted_seconds}
    end)
  end

  defp get_wait_time_stats_from_history(board_id, start_date, exclude_weekends) do
    first_move_subquery =
      from th in TaskHistory,
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
      |> select([t, _c, fm], %{
        wait_time_seconds:
          fragment("GREATEST(0, EXTRACT(EPOCH FROM (? - ?)))", fm.first_moved_at, t.inserted_at),
        start_time: t.inserted_at,
        end_time: fm.first_moved_at
      })

    backlog_results =
      backlog_query
      |> Repo.all()
      |> Enum.map(fn result ->
        %{
          result
          | start_time: normalize_to_datetime(result.start_time),
            end_time: normalize_to_datetime(result.end_time)
        }
      end)
      |> apply_weekend_filter(exclude_weekends)

    empty_stats = %{average_hours: 0, median_hours: 0, min_hours: 0, max_hours: 0, count: 0}

    with {:ok, backlog_stats} <- calculate_wait_time_stats(backlog_results) do
      {:ok, %{review_wait: empty_stats, backlog_wait: backlog_stats}}
    end
  end

  # Private helper functions

  defp board_ai_optimized?(board_id) do
    from(b in Board, where: b.id == ^board_id, select: b.ai_optimized_board)
    |> Repo.one()
    |> Kernel.||(false)
  end

  @date_range_days %{today: 0, last_7_days: 6, last_30_days: 29, last_90_days: 89}

  defp get_start_date(:all_time), do: DateTime.new!(~D[2000-01-01], ~T[00:00:00])

  defp get_start_date(range) do
    days_back = Map.get(@date_range_days, range, 29)

    DateTime.utc_now()
    |> DateTime.to_date()
    |> Date.add(-days_back)
    |> DateTime.new!(~T[00:00:00])
  end

  defp maybe_filter_by_agent(query, nil), do: query

  defp maybe_filter_by_agent(query, agent_name) do
    where(query, [t], t.completed_by_agent == ^agent_name or t.created_by_agent == ^agent_name)
  end

  defp calculate_time_stats([]),
    do: {:ok, %{average_hours: 0, median_hours: 0, min_hours: 0, max_hours: 0, count: 0}}

  defp calculate_time_stats(results) when is_list(results) do
    time_key = determine_time_key(List.first(results))
    calculate_time_stats_for_key(results, time_key)
  end

  defp calculate_time_stats_for_key([], _key),
    do: {:ok, %{average_hours: 0, median_hours: 0, min_hours: 0, max_hours: 0, count: 0}}

  defp calculate_time_stats_for_key(results, time_key) do
    times_in_hours =
      results
      |> extract_time_values(time_key)
      |> Enum.sort()

    build_stats_response(times_in_hours)
  end

  defp determine_time_key(first_result) do
    cond do
      Map.has_key?(first_result, :cycle_time_seconds) -> :cycle_time_seconds
      Map.has_key?(first_result, :lead_time_seconds) -> :lead_time_seconds
      true -> :wait_time_seconds
    end
  end

  defp extract_time_values(results, time_key) do
    results
    |> Enum.map(fn result -> Map.get(result, time_key) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&convert_seconds_to_hours/1)
  end

  defp convert_seconds_to_hours(seconds) do
    seconds_float =
      if is_struct(seconds, Decimal), do: Decimal.to_float(seconds), else: seconds

    seconds_float / 3600
  end

  defp build_stats_response([]) do
    {:ok, %{average_hours: 0, median_hours: 0, min_hours: 0, max_hours: 0, count: 0}}
  end

  defp build_stats_response(times_in_hours) do
    count = length(times_in_hours)
    average = Enum.sum(times_in_hours) / count
    median = calculate_median(times_in_hours)
    min = Enum.min(times_in_hours)
    max = Enum.max(times_in_hours)

    {:ok,
     %{
       average_hours: Float.round(average, 4),
       median_hours: Float.round(median, 4),
       min_hours: Float.round(min, 4),
       max_hours: Float.round(max, 4),
       count: count
     }}
  end

  defp calculate_wait_time_stats(results) do
    calculate_time_stats_for_key(results, :wait_time_seconds)
  end

  defp calculate_median([]), do: 0

  defp calculate_median(sorted_list) do
    count = length(sorted_list)
    middle = div(count, 2)

    if rem(count, 2) == 0 do
      (Enum.at(sorted_list, middle - 1) + Enum.at(sorted_list, middle)) / 2
    else
      Enum.at(sorted_list, middle)
    end
  end

  # Calculate business time (excluding weekends) between two DateTimes or NaiveDateTimes
  defp calculate_business_time(start_time, end_time) do
    # Normalize to DateTime if needed
    start_dt = normalize_to_datetime(start_time)
    end_dt = normalize_to_datetime(end_time)

    # Convert to Date for day-of-week checking
    start_date = DateTime.to_date(start_dt)
    end_date = DateTime.to_date(end_dt)

    # Calculate total seconds
    total_seconds = DateTime.diff(end_dt, start_dt, :second)

    # Count weekend days in the range
    step = if Date.compare(start_date, end_date) == :gt, do: -1, else: 1

    weekend_days =
      Date.range(start_date, end_date, step)
      |> Enum.count(fn date -> Date.day_of_week(date) in [6, 7] end)

    # Subtract weekend time (assuming 24-hour days)
    business_seconds = total_seconds - weekend_days * 86_400

    max(business_seconds, 0)
  end

  defp normalize_to_datetime(%DateTime{} = dt), do: dt

  defp normalize_to_datetime(%NaiveDateTime{} = ndt) do
    DateTime.from_naive!(ndt, "Etc/UTC")
  end

  # ===================================================================
  # Workspace-level read functions (W579)
  # ===================================================================

  @workspace_window_days 14
  @allowed_window_days [7, 14, 30, 90]
  @workspace_agent_leaderboard_limit 6

  @doc """
  Returns the workspace KPI strip — median cycle time, p75 lead time,
  per-day throughput, and median review wait — with delta percentages
  vs the previous equal-length window.

  Returns the zero map when the scoped user has no boards.

  ## Options

    * `:scope` — a `Kanban.Accounts.Scope.t/0`. When `nil` or its user
      is `nil`, the function returns the zero map.
    * `:window_days` — the trailing window length in days. Allow-listed
      to #{inspect(@allowed_window_days)}; any other value (including
      `nil` or an absent option) falls back to #{@workspace_window_days}.
      The previous window used for the delta percentages always matches
      the resolved window length.
    * `:timezone` — the viewer's IANA timezone, accepted by every
      workspace read for local-day bucketing. Defaults to `"Etc/UTC"`
      when omitted or unknown; the day-boundary conversion that consumes
      it is layered on in later work, so the option is currently a
      no-op pass-through.
  """
  @spec workspace_kpis(keyword()) :: %{
          cycle_time_median_minutes: non_neg_integer(),
          cycle_time_delta_pct: float(),
          lead_time_p75_minutes: non_neg_integer(),
          lead_time_delta_pct: float(),
          throughput_per_day: float(),
          throughput_delta_pct: float(),
          review_wait_minutes: non_neg_integer(),
          review_wait_delta_pct: float()
        }
  def workspace_kpis(opts \\ []) do
    case scoped_board_ids(opts) do
      [] ->
        zero_kpis()

      board_ids ->
        window_days = resolve_window_days(opts)
        now = DateTime.utc_now()
        current_start = shift_days(now, -window_days)
        previous_start = shift_days(now, -2 * window_days)

        current = completed_tasks_in_window(board_ids, current_start, now)
        previous = completed_tasks_in_window(board_ids, previous_start, current_start)

        build_kpis(current, previous, window_days)
    end
  end

  @doc """
  Returns the most recent days of median cycle time, split by
  `created_by_agent` presence.

  Each entry is `%{date: Date.t(), agent_minutes: integer(),
  human_minutes: integer()}` ordered oldest-to-newest. Days with no
  completed tasks render zeros. The series length is the resolved
  `:window_days` option (default #{@workspace_window_days}).
  """
  @spec cycle_time_daily(keyword()) :: [
          %{date: Date.t(), agent_minutes: non_neg_integer(), human_minutes: non_neg_integer()}
        ]
  def cycle_time_daily(opts \\ []) do
    window_days = resolve_window_days(opts)

    case scoped_board_ids(opts) do
      [] -> empty_day_series(&zero_cycle_entry/1, window_days)
      board_ids -> build_cycle_time_daily(board_ids, window_days)
    end
  end

  defp zero_cycle_entry(date), do: %{date: date, agent_minutes: 0, human_minutes: 0}

  defp build_cycle_time_daily(board_ids, window_days) do
    now = DateTime.utc_now()
    window_start = shift_days(now, -window_days + 1)

    per_day =
      board_ids
      |> completed_tasks_in_window(window_start, now)
      |> bucket_cycle_minutes()

    now
    |> day_range(window_days)
    |> Enum.map(&cycle_entry_for(&1, per_day))
  end

  defp cycle_entry_for(date, per_day) do
    per_day
    |> Map.get(date, %{agent_minutes: 0, human_minutes: 0})
    |> Map.put(:date, date)
  end

  defp bucket_cycle_minutes(tasks) do
    tasks
    |> Enum.group_by(&completed_on_date/1)
    |> Map.new(&cycle_bucket_entry/1)
  end

  defp cycle_bucket_entry({date, tasks}) do
    {date,
     %{
       agent_minutes: tasks |> Enum.filter(&agent_task?/1) |> median_cycle_minutes(),
       human_minutes: tasks |> Enum.reject(&agent_task?/1) |> median_cycle_minutes()
     }}
  end

  @doc """
  Returns the most recent daily completion counts, oldest-to-newest.

  The series length is the resolved `:window_days` option
  (default #{@workspace_window_days}).
  """
  @spec throughput_daily(keyword()) :: [non_neg_integer()]
  def throughput_daily(opts \\ []) do
    window_days = resolve_window_days(opts)

    case scoped_board_ids(opts) do
      [] -> List.duplicate(0, window_days)
      board_ids -> build_throughput_daily(board_ids, window_days)
    end
  end

  defp build_throughput_daily(board_ids, window_days) do
    now = DateTime.utc_now()
    window_start = shift_days(now, -window_days + 1)

    counts =
      board_ids
      |> completed_tasks_in_window(window_start, now)
      |> Enum.frequencies_by(&completed_on_date/1)

    now
    |> day_range(window_days)
    |> Enum.map(&Map.get(counts, &1, 0))
  end

  @doc """
  Returns up to six contributors (agents before humans, descending by
  completed count) for the trailing window (the resolved `:window_days`
  option, default #{@workspace_window_days}).

  Each entry is `%{name: String.t(), kind: :agent | :human,
  completed: non_neg_integer(), success_pct: float()}`. `success_pct`
  is the fraction of the contributor's window completions that were
  either approved (`review_status == :approved`) or did not need
  review at all, expressed as a percent.
  """
  @spec agent_leaderboard(keyword()) :: [
          %{
            name: String.t(),
            kind: :agent | :human,
            completed: non_neg_integer(),
            success_pct: float()
          }
        ]
  def agent_leaderboard(opts \\ []) do
    window_days = resolve_window_days(opts)

    case scoped_board_ids(opts) do
      [] -> []
      board_ids -> build_agent_leaderboard(board_ids, window_days)
    end
  end

  defp build_agent_leaderboard(board_ids, window_days) do
    now = DateTime.utc_now()
    window_start = shift_days(now, -window_days + 1)

    tasks =
      board_ids
      |> completed_tasks_in_window(window_start, now)
      |> Repo.preload(:completed_by)

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

  @doc """
  Returns daily cumulative-flow snapshots, oldest-to-newest. Each
  snapshot has integer counts for `:backlog`, `:ready`, `:doing`,
  `:review`, and `:done`. See the `@moduledoc` for the per-state
  approximation rules. The series length is the resolved `:window_days`
  option (default #{@workspace_window_days}).
  """
  @spec cumulative_flow(keyword()) :: [
          %{
            date: Date.t(),
            backlog: non_neg_integer(),
            ready: non_neg_integer(),
            doing: non_neg_integer(),
            review: non_neg_integer(),
            done: non_neg_integer()
          }
        ]
  def cumulative_flow(opts \\ []) do
    window_days = resolve_window_days(opts)

    case scoped_board_ids(opts) do
      [] -> empty_day_series(&zero_flow_snapshot/1, window_days)
      board_ids -> build_cumulative_flow(board_ids, window_days)
    end
  end

  defp build_cumulative_flow(board_ids, window_days) do
    now = DateTime.utc_now()
    tasks = workspace_tasks(board_ids)

    now
    |> day_range(window_days)
    |> Enum.map(&cfd_snapshot(tasks, &1))
  end

  # --- Workspace helpers ----------------------------------------------------

  defp scoped_board_ids(opts) do
    case Keyword.get(opts, :scope) do
      %Scope{user: %{} = user} ->
        user
        |> Boards.list_boards()
        |> Enum.map(& &1.id)
        |> filter_board_ids(Keyword.get(opts, :board_ids))

      _ ->
        []
    end
  end

  # Restrict the visible board ids to an optional client-supplied subset.
  # nil means "no filter" (return all visible ids, unchanged behavior). A list
  # is treated as untrusted input: intersect it with the visible ids so ids the
  # user cannot see are silently dropped. Always returns a plain list of ids.
  defp filter_board_ids(visible_ids, nil), do: visible_ids

  defp filter_board_ids(visible_ids, requested_ids) when is_list(requested_ids) do
    visible_set = MapSet.new(visible_ids)

    requested_ids
    |> Enum.uniq()
    |> Enum.filter(&MapSet.member?(visible_set, &1))
  end

  # Resolve the trailing window length from an untrusted client option.
  # The value bounds already board-scoped queries, so it is restricted to
  # a fixed allow-list — any unsupported value (including `nil` or an
  # absent option) falls back to the default so a forged number can never
  # force an unbounded or very large scan.
  defp resolve_window_days(opts) do
    case Keyword.get(opts, :window_days) do
      days when days in @allowed_window_days -> days
      _ -> @workspace_window_days
    end
  end

  defp completed_tasks_in_window(board_ids, %DateTime{} = window_start, %DateTime{} = window_end) do
    Task
    |> join(:inner, [t], c in assoc(t, :column))
    |> where([t, c], c.board_id in ^board_ids)
    |> where([t, _c], not is_nil(t.completed_at))
    |> where([t, _c], t.completed_at >= ^window_start)
    |> where([t, _c], t.completed_at <= ^window_end)
    |> Repo.all()
  end

  # Loads every task across every visible board into memory; `cumulative_flow/1`
  # iterates the result 14 times to bucket per-day snapshots. Acceptable at
  # current workspace sizes — once any workspace exceeds ~10k tasks, push the
  # bucketing into SQL (or project a daily snapshot table) so the LiveView
  # mount stays under its budget. Flagged in W579 reviewer notes.
  defp workspace_tasks(board_ids) do
    Task
    |> join(:inner, [t], c in assoc(t, :column))
    |> where([t, c], c.board_id in ^board_ids)
    |> Repo.all()
  end

  defp zero_kpis do
    %{
      cycle_time_median_minutes: 0,
      cycle_time_delta_pct: 0.0,
      lead_time_p75_minutes: 0,
      lead_time_delta_pct: 0.0,
      throughput_per_day: 0.0,
      throughput_delta_pct: 0.0,
      review_wait_minutes: 0,
      review_wait_delta_pct: 0.0
    }
  end

  defp build_kpis(current, previous, window_days) do
    cycle_current = median_cycle_minutes(current)
    cycle_previous = median_cycle_minutes(previous)

    lead_current = percentile_lead_minutes(current, 75)
    lead_previous = percentile_lead_minutes(previous, 75)

    throughput_current = length(current) / window_days
    throughput_previous = length(previous) / window_days

    review_current = median_review_wait_minutes(current)
    review_previous = median_review_wait_minutes(previous)

    %{
      cycle_time_median_minutes: cycle_current,
      cycle_time_delta_pct: delta_pct(cycle_current, cycle_previous),
      lead_time_p75_minutes: lead_current,
      lead_time_delta_pct: delta_pct(lead_current, lead_previous),
      throughput_per_day: throughput_current,
      throughput_delta_pct: delta_pct(throughput_current, throughput_previous),
      review_wait_minutes: review_current,
      review_wait_delta_pct: delta_pct(review_current, review_previous)
    }
  end

  # Public spec lists delta_pct as a private helper. Implements
  # divide-by-zero safety: a 0 previous window collapses to 0.0%.
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

  defp agent_task?(%{created_by_agent: agent}) when is_binary(agent) and agent != "", do: true
  defp agent_task?(_), do: false

  defp human_completion?(%{completed_by_agent: agent}) when is_binary(agent) and agent != "",
    do: false

  defp human_completion?(%{completed_by_id: id}) when is_integer(id), do: true
  defp human_completion?(_), do: false

  defp human_name(%{completed_by: %{name: name}}) when is_binary(name) and name != "", do: name
  defp human_name(%{completed_by: %{email: email}}) when is_binary(email), do: email
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

  defp completed_on_date(%{completed_at: %DateTime{} = dt}), do: DateTime.to_date(dt)
  defp completed_on_date(_), do: nil

  defp day_range(%DateTime{} = now, window_days) do
    today = DateTime.to_date(now)

    (-window_days + 1)..0
    |> Enum.map(&Date.add(today, &1))
  end

  defp empty_day_series(builder, window_days) when is_function(builder, 1) do
    DateTime.utc_now()
    |> day_range(window_days)
    |> Enum.map(builder)
  end

  defp shift_days(%DateTime{} = dt, days) when is_integer(days) do
    DateTime.add(dt, days * 86_400, :second)
  end

  defp zero_flow_snapshot(date) do
    %{date: date, backlog: 0, ready: 0, doing: 0, review: 0, done: 0}
  end

  defp cfd_snapshot(tasks, date) do
    eod = end_of_day(date)
    visible = Enum.reject(tasks, &archived_before?(&1, eod))
    counts = cfd_bucket_counts(visible, eod)

    Map.put(counts, :date, date)
  end

  defp cfd_bucket_counts(visible, eod) do
    %{
      backlog: Enum.count(visible, &backlog_at?(&1, eod)),
      ready: 0,
      doing: Enum.count(visible, &doing_at?(&1, eod)),
      review: Enum.count(visible, &review_at?(&1, eod)),
      done: Enum.count(visible, &done_at?(&1, eod))
    }
  end

  defp end_of_day(date) do
    {:ok, dt} = DateTime.new(date, ~T[23:59:59], "Etc/UTC")
    dt
  end

  defp archived_before?(%{archived_at: %DateTime{} = a}, eod),
    do: DateTime.compare(a, eod) != :gt

  defp archived_before?(_, _), do: false

  defp inserted_before?(%{inserted_at: %NaiveDateTime{} = i}, eod) do
    i
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.compare(eod)
    |> Kernel.!=(:gt)
  end

  defp inserted_before?(_, _), do: false

  defp backlog_at?(task, eod) do
    inserted_before?(task, eod) and is_nil(task.claimed_at)
  end

  defp doing_at?(task, eod) do
    claimed_at_or_before?(task, eod) and not completed_at_or_before?(task, eod)
  end

  defp review_at?(task, eod) do
    task.needs_review and completed_at_or_before?(task, eod) and
      not reviewed_at_or_before?(task, eod)
  end

  defp done_at?(task, eod) do
    reviewed_at_or_before?(task, eod) or
      (completed_at_or_before?(task, eod) and not task.needs_review)
  end

  defp claimed_at_or_before?(%{claimed_at: %DateTime{} = dt}, eod),
    do: DateTime.compare(dt, eod) != :gt

  defp claimed_at_or_before?(_, _), do: false

  defp completed_at_or_before?(%{completed_at: %DateTime{} = dt}, eod),
    do: DateTime.compare(dt, eod) != :gt

  defp completed_at_or_before?(_, _), do: false

  defp reviewed_at_or_before?(%{reviewed_at: %DateTime{} = dt}, eod),
    do: DateTime.compare(dt, eod) != :gt

  defp reviewed_at_or_before?(_, _), do: false
end
