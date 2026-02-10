defmodule Kanban.Metrics do
  @moduledoc """
  The Metrics context for querying and aggregating task data for lean metrics calculations.

  Provides functions to calculate throughput, cycle time, lead time, and wait time statistics
  for kanban boards.
  """

  import Ecto.Query, warn: false

  alias Kanban.Boards.Board
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
    with {:ok, throughput} <- get_throughput(board_id, opts),
         {:ok, cycle_time} <- get_cycle_time_stats(board_id, opts),
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

    query =
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

    results = Repo.all(query)

    filtered_results =
      if exclude_weekends do
        Enum.reject(results, fn %{date: date} ->
          Date.day_of_week(date) in [6, 7]
        end)
      else
        results
      end

    {:ok, filtered_results}
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
    else
      get_wait_time_stats_from_history(board_id, start_date, exclude_weekends)
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
            "EXTRACT(EPOCH FROM (? - ?))",
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
            "EXTRACT(EPOCH FROM (? - ?))",
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
          fragment("EXTRACT(EPOCH FROM (? - ?))", fm.first_moved_at, t.inserted_at),
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

  defp get_start_date(:today) do
    DateTime.utc_now()
    |> DateTime.to_date()
    |> DateTime.new!(~T[00:00:00])
  end

  defp get_start_date(:last_7_days) do
    DateTime.utc_now()
    |> DateTime.to_date()
    |> Date.add(-6)
    |> DateTime.new!(~T[00:00:00])
  end

  defp get_start_date(:last_30_days) do
    DateTime.utc_now()
    |> DateTime.to_date()
    |> Date.add(-29)
    |> DateTime.new!(~T[00:00:00])
  end

  defp get_start_date(:last_90_days) do
    DateTime.utc_now()
    |> DateTime.to_date()
    |> Date.add(-89)
    |> DateTime.new!(~T[00:00:00])
  end

  defp get_start_date(:all_time) do
    DateTime.new!(~D[2000-01-01], ~T[00:00:00])
  end

  defp get_start_date(_), do: get_start_date(:last_30_days)

  defp maybe_filter_by_agent(query, nil), do: query

  defp maybe_filter_by_agent(query, agent_name) do
    where(query, [t], t.completed_by_agent == ^agent_name or t.created_by_agent == ^agent_name)
  end

  defp calculate_time_stats([]),
    do: {:ok, %{average_hours: 0, median_hours: 0, min_hours: 0, max_hours: 0, count: 0}}

  defp calculate_time_stats(results) when is_list(results) do
    first_result = List.first(results)
    time_key = determine_time_key(first_result)

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

  defp calculate_wait_time_stats([]),
    do: {:ok, %{average_hours: 0, median_hours: 0, min_hours: 0, max_hours: 0, count: 0}}

  defp calculate_wait_time_stats(results) when is_list(results) do
    times_in_hours =
      results
      |> Enum.map(fn result -> result.wait_time_seconds end)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn seconds ->
        # Convert to float if it's a Decimal
        seconds_float =
          if is_struct(seconds, Decimal), do: Decimal.to_float(seconds), else: seconds

        seconds_float / 3600
      end)
      |> Enum.sort()

    case times_in_hours do
      [] ->
        {:ok, %{average_hours: 0, median_hours: 0, min_hours: 0, max_hours: 0, count: 0}}

      _ ->
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
end
