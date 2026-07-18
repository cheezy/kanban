defmodule Kanban.Metrics do
  @moduledoc """
  The Metrics context for querying and aggregating task data for lean metrics calculations.

  Provides functions to calculate throughput, cycle time, lead time, and wait time statistics
  for kanban boards.

  Workspace-level (cross-board) reads — `workspace_kpis/1`, `cycle_time_daily/1`,
  `throughput_daily/1`, `agent_leaderboard/1`, and `cumulative_flow/1` — live in
  `Kanban.Metrics.Workspace` (extracted in W1439).
  """

  import Ecto.Query, warn: false

  alias Kanban.Boards.Board
  alias Kanban.Metrics.BusinessTime
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskHistory
  alias Kanban.Timezone

  # Trailing-window lengths (days back from "today", inclusive) for the board
  # time-range options. Consumed by local_window_start/2 for the throughput and
  # the cycle/lead/wait stats windows.
  @date_range_days %{today: 0, last_7_days: 6, last_30_days: 29, last_90_days: 89}

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
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")

    start_date = local_window_start(time_range, timezone)

    results =
      board_id
      |> throughput_query(start_date, agent_name)
      |> Repo.all()
      |> bucket_by_local_day(timezone)

    {:ok, maybe_reject_weekends(results, exclude_weekends)}
  end

  # The window start as the UTC instant of local midnight `days` ago, so the
  # "last N days" boundary matches the viewer's wall clock. `:all_time` keeps the
  # fixed sentinel; "Etc/UTC" reproduces the prior UTC-midnight behavior.
  defp local_window_start(:all_time, _timezone),
    do: DateTime.new!(~D[2000-01-01], ~T[00:00:00])

  defp local_window_start(range, timezone) do
    days_back = Map.get(@date_range_days, range, 29)

    timezone
    |> Timezone.local_today()
    |> Date.add(-days_back)
    |> Timezone.start_of_local_day(timezone)
  end

  # Counts completions per local calendar day in `timezone`. Bucketing in Elixir
  # (rather than SQL DATE()) is what makes a 23:30-local completion land on the
  # viewer's day instead of the next UTC day. Sparse by design — only days with
  # completions appear — matching the prior contract.
  defp bucket_by_local_day(completed_ats, timezone) do
    completed_ats
    |> Enum.group_by(&Timezone.local_date(&1, timezone))
    |> Enum.map(fn {date, day_completions} -> %{date: date, count: length(day_completions)} end)
    |> Enum.sort_by(& &1.date, Date)
  end

  defp throughput_query(board_id, start_date, agent_name) do
    Task
    |> join(:inner, [t], c in assoc(t, :column))
    |> where([t, c], c.board_id == ^board_id)
    |> where([t], not is_nil(t.completed_at))
    |> where([t], t.completed_at >= ^start_date)
    |> where([t], t.type != ^:goal)
    |> maybe_filter_by_agent(agent_name)
    |> select([t], t.completed_at)
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
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")
    start_date = local_window_start(time_range, timezone)

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

    timezone = Keyword.get(opts, :timezone, "Etc/UTC")
    start_date = local_window_start(time_range, timezone)

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

  The `:time_range` window bounds the **end** of each wait interval — the
  timestamp that closes the wait (`reviewed_at` for review wait, `claimed_at`
  or the first column move for backlog wait). This is the same bound the
  matching task-list queries in `Kanban.Metrics.TaskQueries` apply, so the
  statistics and the listed tasks always describe the same population. A long
  wait that *started* before the window but ended inside it is counted.

  Regular (non AI-optimized) boards have no review step, so `:review_wait`
  is an explicit not-applicable placeholder of zeros for them — mirroring
  `TaskQueries.get_review_wait_tasks/2`, which returns `[]`. Every consumer
  must guard the review-wait section on `board.ai_optimized_board` rather than
  render the placeholder as a real measurement.

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
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")
    start_date = local_window_start(time_range, timezone)

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
      |> where([t], t.reviewed_at >= ^start_date)
      |> where([t], t.type != ^:goal)
      |> maybe_filter_by_completing_agent(agent_name)
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
      |> where([t], t.claimed_at >= ^start_date)
      |> where([t], t.type != ^:goal)
      |> maybe_filter_by_completing_agent(agent_name)
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
      |> where([t, _c, fm], fm.first_moved_at >= ^start_date)
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

    # Regular boards have no review step, so review wait is not measurable
    # rather than measured-as-zero. Consumers guard this section on
    # `board.ai_optimized_board` (the Wait Time page, the dashboard card, the
    # Excel export and the PDF export all do) so the placeholder is never
    # published as a real figure.
    not_applicable_stats = %{
      average_hours: 0,
      median_hours: 0,
      min_hours: 0,
      max_hours: 0,
      count: 0
    }

    with {:ok, backlog_stats} <- calculate_wait_time_stats(backlog_results) do
      {:ok, %{review_wait: not_applicable_stats, backlog_wait: backlog_stats}}
    end
  end

  # Private helper functions

  defp board_ai_optimized?(board_id) do
    from(b in Board, where: b.id == ^board_id, select: b.ai_optimized_board)
    |> Repo.one()
    |> Kernel.||(false)
  end

  defp maybe_filter_by_agent(query, nil), do: query

  defp maybe_filter_by_agent(query, agent_name) do
    where(query, [t], t.completed_by_agent == ^agent_name or t.created_by_agent == ^agent_name)
  end

  # The wait-time statistics must describe exactly the population the wait-time
  # task lists render, under every filter the page exposes — including the agent
  # filter. `Kanban.Metrics.TaskQueries` matches the completing agent only, so
  # the wait-time stats do the same. The broader creator-OR-completer predicate
  # above is deliberate for throughput, cycle time and lead time (see the "agent
  # filtering edge cases" tests) and is left alone.
  defp maybe_filter_by_completing_agent(query, nil), do: query

  defp maybe_filter_by_completing_agent(query, agent_name) do
    where(query, [t], t.completed_by_agent == ^agent_name)
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

  defp calculate_median(sorted_list) do
    count = length(sorted_list)
    middle = div(count, 2)

    if rem(count, 2) == 0 do
      (Enum.at(sorted_list, middle - 1) + Enum.at(sorted_list, middle)) / 2
    else
      Enum.at(sorted_list, middle)
    end
  end

  # Elapsed seconds minus the part of the interval that falls on a weekend.
  # See `Kanban.Metrics.BusinessTime` for the overlap arithmetic and the zero
  # clamp that keeps out-of-order timestamps non-negative.
  defp calculate_business_time(start_time, end_time) do
    BusinessTime.business_seconds(start_time, end_time)
  end

  defp normalize_to_datetime(value), do: BusinessTime.to_utc_datetime(value)
end
