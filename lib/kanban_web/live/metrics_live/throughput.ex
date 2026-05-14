defmodule KanbanWeb.MetricsLive.Throughput do
  use KanbanWeb, :live_view
  use KanbanWeb.MetricsLive.Base, page_title: "Throughput Metrics"

  import Ecto.Query
  import KanbanWeb.MetricsLive.Components

  alias Kanban.Metrics
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias KanbanWeb.MetricsLive.Helpers

  @impl KanbanWeb.MetricsLive.Base
  def load_data(socket) do
    opts = build_throughput_opts(socket)

    {:ok, throughput} = Metrics.get_throughput(socket.assigns.board.id, opts)
    stats = calculate_summary_stats(throughput)
    tasks = get_throughput_tasks(socket.assigns.board.id, opts)
    grouped_tasks = group_tasks_by_date(tasks)
    goals = get_completed_goals(socket.assigns.board.id, opts)

    socket
    |> assign(:throughput, throughput)
    |> assign(:summary_stats, stats)
    |> assign(:tasks, tasks)
    |> assign(:grouped_tasks, grouped_tasks)
    |> assign(:completed_goals, goals)
  end

  defp build_throughput_opts(socket) do
    opts = [
      time_range: socket.assigns.time_range,
      exclude_weekends: socket.assigns.exclude_weekends
    ]

    if socket.assigns.agent_name do
      Keyword.put(opts, :agent_name, socket.assigns.agent_name)
    else
      opts
    end
  end

  defp get_throughput_tasks(board_id, opts) do
    time_range = Keyword.get(opts, :time_range, :last_30_days)
    agent_name = Keyword.get(opts, :agent_name)
    start_date = Helpers.get_start_date(time_range)

    query =
      Task
      |> join(:inner, [t], c in assoc(t, :column))
      |> where([t, c], c.board_id == ^board_id)
      |> where([t], not is_nil(t.completed_at))
      |> where([t], t.completed_at >= ^start_date)
      |> where([t], t.type != ^:goal)
      |> order_by([t], desc: t.completed_at)
      |> select([t], %{
        id: t.id,
        identifier: t.identifier,
        title: t.title,
        inserted_at: t.inserted_at,
        claimed_at: t.claimed_at,
        completed_at: t.completed_at,
        completed_by_agent: t.completed_by_agent
      })

    query =
      if agent_name do
        where(query, [t], t.completed_by_agent == ^agent_name)
      else
        query
      end

    Repo.all(query)
  end

  defp get_completed_goals(board_id, opts) do
    time_range = Keyword.get(opts, :time_range, :last_30_days)
    agent_name = Keyword.get(opts, :agent_name)
    start_date = Helpers.get_start_date(time_range)

    query =
      Task
      |> join(:inner, [t], c in assoc(t, :column))
      |> where([t, c], c.board_id == ^board_id)
      |> where([t], t.type == ^:goal)
      |> where(
        [t, c],
        not is_nil(t.completed_at) or fragment("lower(?)", c.name) == "done"
      )
      |> where(
        [t],
        coalesce(t.completed_at, t.updated_at) >= ^start_date
      )
      |> order_by([t], desc: coalesce(t.completed_at, t.updated_at))
      |> select([t], %{
        id: t.id,
        identifier: t.identifier,
        title: t.title,
        inserted_at: t.inserted_at,
        completed_at: coalesce(t.completed_at, t.updated_at),
        completed_by_agent: t.completed_by_agent
      })

    query =
      if agent_name do
        where(query, [t], t.completed_by_agent == ^agent_name)
      else
        query
      end

    Repo.all(query)
  end

  defp calculate_summary_stats([_ | _] = throughput) do
    total = Enum.reduce(throughput, 0, fn day, acc -> acc + day.count end)
    days_count = length(throughput)
    avg_per_day = if days_count > 0, do: total / days_count, else: 0.0

    peak = Enum.max_by(throughput, & &1.count, fn -> %{date: nil, count: 0} end)

    %{
      total: total,
      avg_per_day: Float.round(avg_per_day, 1),
      peak_day: peak.date,
      peak_count: peak.count
    }
  end

  defp calculate_summary_stats(_), do: %{total: 0, avg_per_day: 0.0, peak_day: nil, peak_count: 0}

  # Used in throughput.html.heex (analyzer does not scan HEEx files).
  defp format_date(nil), do: "N/A"

  defp format_date(date) do
    Calendar.strftime(date, "%b %d, %Y")
  end

  # Used in throughput.html.heex (analyzer does not scan HEEx files).
  defp format_datetime(nil), do: "N/A"

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y %I:%M %p")
  end

  # Used in throughput.html.heex (analyzer does not scan HEEx files).
  defp calculate_bar_width(_count, 0), do: 0
  defp calculate_bar_width(0, _peak), do: 0

  defp calculate_bar_width(count, peak) when count > 0 and peak > 0 do
    (count / peak * 100) |> Float.round(1)
  end

  defp group_tasks_by_date(tasks) do
    tasks
    |> Enum.group_by(fn task ->
      task.completed_at
      |> DateTime.to_date()
    end)
    |> Enum.sort_by(fn {date, _tasks} -> date end, {:desc, Date})
    |> Enum.map(fn {date, day_tasks} ->
      {date, Enum.sort_by(day_tasks, & &1.completed_at, {:desc, DateTime})}
    end)
  end
end
