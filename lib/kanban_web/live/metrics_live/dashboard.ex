defmodule KanbanWeb.MetricsLive.Dashboard do
  use KanbanWeb, :live_view
  use KanbanWeb.MetricsLive.Base, page_title: "Metrics Dashboard"

  import KanbanWeb.MetricsLive.Components

  @impl KanbanWeb.MetricsLive.Base
  def load_data(socket) do
    opts = build_dashboard_opts(socket)

    case metrics_module().get_dashboard_summary(socket.assigns.board.id, opts) do
      {:ok, summary} ->
        assign_dashboard_summary(socket, summary)

      {:error, _reason} ->
        assign_empty_dashboard(socket)
    end
  end

  # Testability seam: allows the test suite to inject a stub module that
  # returns `{:error, _}` from `get_dashboard_summary/2` so the
  # empty-dashboard fallback path can be exercised. Production code always
  # gets `Kanban.Metrics`.
  defp metrics_module do
    Application.get_env(:kanban, :metrics_module, Kanban.Metrics)
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

  @doc """
  Formats an hour-count number for display.

    * `0` → `"0h"`
    * `<1` → minutes (e.g. `0.5` → `"30.0m"`)
    * `1..23` → hours (e.g. `1.5` → `"1.5h"`)
    * `>=24` → days (e.g. `48` → `"2.0d"`)
    * anything else (e.g. `nil`, `:atom`) → `"N/A"`

  Public so the test suite can exercise the non-numeric catch-all
  branch directly without having to coerce a Metrics summary into a
  shape that includes nil hour values.
  """
  def format_hours(hours) when is_number(hours) and hours == 0, do: "0h"

  def format_hours(hours) when is_number(hours) do
    hours_float = hours / 1

    cond do
      hours_float < 1 -> "#{Float.round(hours_float * 60, 1)}m"
      hours_float < 24 -> "#{Float.round(hours_float, 1)}h"
      true -> "#{Float.round(hours_float / 24, 1)}d"
    end
  end

  def format_hours(_), do: "N/A"

  defp total_throughput(throughput) do
    Enum.reduce(throughput, 0, fn %{count: count}, acc -> acc + count end)
  end
end
