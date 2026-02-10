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
  def handle_params(%{"id" => board_id} = params, _, socket) do
    user = socket.assigns.current_scope.user
    board = Boards.get_board!(board_id, user)
    user_access = Boards.get_user_access(board.id, user.id)

    {:ok, agents} = Metrics.get_agents(board.id)

    time_range = parse_time_range(params["time_range"])
    agent_name = parse_agent_name(params["agent_name"])
    exclude_weekends = parse_exclude_weekends(params["exclude_weekends"])

    socket =
      socket
      |> assign(:page_title, "Metrics Dashboard")
      |> assign(:board, board)
      |> assign(:user_access, user_access)
      |> assign(:agents, agents)
      |> assign(:time_range, time_range)
      |> assign(:agent_name, agent_name)
      |> assign(:exclude_weekends, exclude_weekends)
      |> load_dashboard_data()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_change", params, socket) do
    time_range_atom = String.to_existing_atom(params["time_range"])
    agent_name = if params["agent_name"] == "", do: nil, else: params["agent_name"]
    exclude_weekends = Map.get(params, "exclude_weekends") == "true"

    socket =
      socket
      |> assign(:time_range, time_range_atom)
      |> assign(:agent_name, agent_name)
      |> assign(:exclude_weekends, exclude_weekends)
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

  defp total_throughput(throughput) do
    Enum.reduce(throughput, 0, fn %{count: count}, acc -> acc + count end)
  end

  defp parse_time_range(nil), do: :last_30_days
  defp parse_time_range(""), do: :last_30_days

  defp parse_time_range(time_range) when is_binary(time_range) do
    String.to_existing_atom(time_range)
  rescue
    ArgumentError -> :last_30_days
  end

  defp parse_agent_name(nil), do: nil
  defp parse_agent_name(""), do: nil
  defp parse_agent_name(agent_name) when is_binary(agent_name), do: agent_name

  defp parse_exclude_weekends(nil), do: false
  defp parse_exclude_weekends(""), do: false
  defp parse_exclude_weekends("true"), do: true
  defp parse_exclude_weekends("false"), do: false
  defp parse_exclude_weekends(_), do: false
end
