defmodule KanbanWeb.MetricsLive.LeadTime do
  use KanbanWeb, :live_view
  use KanbanWeb.MetricsLive.Base, page_title: "Lead Time Metrics"

  import KanbanWeb.MetricsLive.Components

  alias Kanban.Metrics
  alias Kanban.Metrics.TaskQueries
  alias KanbanWeb.MetricsLive.Base
  alias KanbanWeb.MetricsLive.Helpers

  @impl KanbanWeb.MetricsLive.Base
  def load_data(socket) do
    Base.load_metric_data(
      socket,
      &Metrics.get_lead_time_stats/2,
      &TaskQueries.get_lead_time_tasks/2,
      :lead_time_seconds,
      :daily_lead_times
    )
  end

  # Used in lead_time.html.heex (analyzer does not scan HEEx files).
  defp format_lead_time(seconds), do: Helpers.format_time(seconds)
  defp format_lead_time_hours(hours), do: Helpers.format_time_hours(hours)
  defp format_datetime(datetime), do: Helpers.format_datetime(datetime)
end
