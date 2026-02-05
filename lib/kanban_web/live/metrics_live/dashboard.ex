defmodule KanbanWeb.MetricsLive.Dashboard do
  use KanbanWeb, :live_view

  alias Kanban.Boards
  alias Kanban.Metrics

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       time_range: :last_30_days,
       agent_name: nil,
       exclude_weekends: false
     )}
  end

  @impl true
  def handle_params(%{"id" => board_id}, _, socket) do
    user = socket.assigns.current_scope.user
    board = Boards.get_board!(board_id, user)
    user_access = Boards.get_user_access(board.id, user.id)

    socket =
      socket
      |> assign(:page_title, "Metrics Dashboard")
      |> assign(:board, board)
      |> assign(:user_access, user_access)
      |> load_dashboard_data()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_time_range", %{"time_range" => time_range}, socket) do
    time_range_atom = String.to_existing_atom(time_range)

    socket =
      socket
      |> assign(:time_range, time_range_atom)
      |> load_dashboard_data()

    {:noreply, socket}
  end

  def handle_event("filter_agent", %{"agent_name" => ""}, socket) do
    socket =
      socket
      |> assign(:agent_name, nil)
      |> load_dashboard_data()

    {:noreply, socket}
  end

  def handle_event("filter_agent", %{"agent_name" => agent_name}, socket) do
    socket =
      socket
      |> assign(:agent_name, agent_name)
      |> load_dashboard_data()

    {:noreply, socket}
  end

  def handle_event("toggle_weekends", %{"exclude_weekends" => exclude_weekends}, socket) do
    exclude_weekends_bool = exclude_weekends == "true"

    socket =
      socket
      |> assign(:exclude_weekends, exclude_weekends_bool)
      |> load_dashboard_data()

    {:noreply, socket}
  end

  defp load_dashboard_data(socket) do
    opts = [
      time_range: socket.assigns.time_range,
      exclude_weekends: socket.assigns.exclude_weekends
    ]

    opts =
      if socket.assigns.agent_name do
        Keyword.put(opts, :agent_name, socket.assigns.agent_name)
      else
        opts
      end

    case Metrics.get_dashboard_summary(socket.assigns.board.id, opts) do
      {:ok, summary} ->
        socket
        |> assign(:throughput, summary.throughput)
        |> assign(:cycle_time, summary.cycle_time)
        |> assign(:lead_time, summary.lead_time)
        |> assign(:wait_time, summary.wait_time)

      {:error, _reason} ->
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
end
