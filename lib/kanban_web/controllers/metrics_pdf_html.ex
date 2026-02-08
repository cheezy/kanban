defmodule KanbanWeb.MetricsPdfHTML do
  use KanbanWeb, :html

  embed_templates "metrics_pdf_html/*"

  defp format_date(nil), do: "N/A"

  defp format_date(date) do
    Calendar.strftime(date, "%b %d, %Y")
  end

  defp format_datetime(nil), do: "N/A"

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y %I:%M %p")
  end

  defp format_time(seconds) do
    KanbanWeb.MetricsLive.Helpers.format_time(seconds)
  end

  defp format_time_range(:today), do: "Today"
  defp format_time_range(:last_7_days), do: "Last 7 Days"
  defp format_time_range(:last_30_days), do: "Last 30 Days"
  defp format_time_range(:last_90_days), do: "Last 90 Days"
  defp format_time_range(:all_time), do: "All Time"
  defp format_time_range(_), do: "Custom Range"

  defp agent_filter_label(nil), do: "All Agents"
  defp agent_filter_label(name), do: name

  defp weekend_filter_label(true), do: "Weekends Excluded"
  defp weekend_filter_label(false), do: "Weekends Included"
end
