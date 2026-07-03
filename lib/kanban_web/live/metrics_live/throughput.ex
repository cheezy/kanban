defmodule KanbanWeb.MetricsLive.Throughput do
  use KanbanWeb, :live_view
  use KanbanWeb.MetricsLive.Base, page_title: "Throughput Metrics"

  import KanbanWeb.MetricsLive.Components

  alias Kanban.Metrics
  alias Kanban.Metrics.TaskQueries
  alias KanbanWeb.MetricsLive.Helpers

  @impl KanbanWeb.MetricsLive.Base
  def load_data(socket) do
    opts = build_throughput_opts(socket)
    board_id = socket.assigns.board.id

    {:ok, throughput} = Metrics.get_throughput(board_id, opts)
    tasks = TaskQueries.get_throughput_tasks(board_id, opts)
    goals = TaskQueries.get_completed_goals(board_id, opts)

    assign_throughput_data(socket, throughput, tasks, goals)
  end

  defp assign_throughput_data(socket, throughput, tasks, goals) do
    timezone = Map.get(socket.assigns, :timezone, "Etc/UTC")

    socket
    |> assign(:throughput, throughput)
    |> assign(:summary_stats, calculate_summary_stats(throughput))
    |> assign(:tasks, tasks)
    |> assign(:grouped_tasks, Helpers.group_tasks_by_completion_date(tasks, timezone))
    |> assign(:completed_goals, goals)
  end

  defp build_throughput_opts(socket) do
    opts = [
      time_range: socket.assigns.time_range,
      exclude_weekends: socket.assigns.exclude_weekends,
      timezone: Map.get(socket.assigns, :timezone, "Etc/UTC")
    ]

    if socket.assigns.agent_name do
      Keyword.put(opts, :agent_name, socket.assigns.agent_name)
    else
      opts
    end
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
end
