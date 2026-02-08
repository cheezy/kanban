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

  defp calculate_bar_width(_count, nil), do: 0
  defp calculate_bar_width(_count, peak) when peak == 0, do: 0

  defp calculate_bar_width(count, peak) when peak > 0 do
    Float.round(count / peak * 100, 1)
  end

  defp format_short_date(date) do
    Calendar.strftime(date, "%b %d")
  end

  defp line_chart_points(daily_times, chart_width, chart_height, max_val) when max_val > 0 do
    count = length(daily_times)
    padding = 0

    daily_times
    |> Enum.with_index()
    |> Enum.map(fn {day, i} ->
      x =
        if count > 1,
          do: padding + i / (count - 1) * (chart_width - 2 * padding),
          else: chart_width / 2

      y = chart_height - day.average_hours / max_val * chart_height
      {Float.round(x * 1.0, 1), Float.round(y * 1.0, 1)}
    end)
  end

  defp line_chart_points(_daily_times, chart_width, chart_height, _max_val) do
    [{Float.round(chart_width / 2.0, 1), Float.round(chart_height / 2.0, 1)}]
  end

  defp points_to_polyline(points) do
    Enum.map_join(points, " ", fn {x, y} -> "#{x},#{y}" end)
  end

  defp line_chart_y_labels(max_val, count) when max_val > 0 do
    Enum.map(0..(count - 1), fn i ->
      Float.round(max_val * i / (count - 1), 1)
    end)
  end

  defp line_chart_y_labels(_max_val, _count), do: [0.0]
end
