defmodule KanbanWeb.MetricsLive.CycleTime do
  use KanbanWeb, :live_view
  use KanbanWeb.MetricsLive.Base, page_title: "Cycle Time Metrics"

  import KanbanWeb.MetricsLive.Components

  alias Kanban.Metrics
  alias Kanban.Metrics.TaskQueries
  alias KanbanWeb.MetricsLive.Base
  alias KanbanWeb.MetricsLive.Helpers

  @impl KanbanWeb.MetricsLive.Base
  def load_data(socket) do
    Base.load_metric_data(
      socket,
      &Metrics.get_cycle_time_stats/2,
      &TaskQueries.get_cycle_time_tasks/2,
      :cycle_time_seconds,
      :daily_cycle_times
    )
  end

  # Used in cycle_time.html.heex (analyzer does not scan HEEx files).
  defp format_cycle_time(seconds), do: Helpers.format_time(seconds)
  defp format_cycle_time_hours(hours), do: Helpers.format_time_hours(hours)
  defp format_datetime(datetime), do: Helpers.format_datetime(datetime)
end
