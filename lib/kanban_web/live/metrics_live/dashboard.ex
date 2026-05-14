defmodule KanbanWeb.MetricsLive.Dashboard do
  use KanbanWeb, :live_view
  use KanbanWeb.MetricsLive.Base, page_title: "Metrics Dashboard"

  import KanbanWeb.MetricsLive.Components

  alias Kanban.Metrics

  @impl KanbanWeb.MetricsLive.Base
  def load_data(socket) do
    opts = build_dashboard_opts(socket)

    case Metrics.get_dashboard_summary(socket.assigns.board.id, opts) do
      {:ok, summary} ->
        assign_dashboard_summary(socket, summary)

      {:error, _reason} ->
        assign_empty_dashboard(socket)
    end
  end

  defp build_dashboard_opts(socket) do
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

  defp assign_dashboard_summary(socket, summary) do
    socket
    |> assign(:throughput, summary.throughput)
    |> assign(:cycle_time, summary.cycle_time)
    |> assign(:lead_time, summary.lead_time)
    |> assign(:wait_time, summary.wait_time)
  end

  defp assign_empty_dashboard(socket) do
    socket
    |> assign(:throughput, [])
    |> assign(:cycle_time, %{average_hours: 0, median_hours: 0, count: 0})
    |> assign(:lead_time, %{average_hours: 0, median_hours: 0, count: 0})
    |> assign(
      :wait_time,
      %{
        review_wait: %{average_hours: 0, median_hours: 0, count: 0},
        backlog_wait: %{average_hours: 0, median_hours: 0, count: 0}
      }
    )
  end

  defp format_hours(hours) when is_number(hours) and hours == 0, do: "0h"

  defp format_hours(hours) when is_number(hours) do
    hours_float = hours / 1

    cond do
      hours_float < 1 -> "#{Float.round(hours_float * 60, 1)}m"
      hours_float < 24 -> "#{Float.round(hours_float, 1)}h"
      true -> "#{Float.round(hours_float / 24, 1)}d"
    end
  end

  defp format_hours(_), do: "N/A"

  defp total_throughput(throughput) do
    Enum.reduce(throughput, 0, fn %{count: count}, acc -> acc + count end)
  end
end
