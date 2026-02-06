defmodule KanbanWeb.MetricsLive.Throughput do
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

    {:ok, agents} = Metrics.get_agents(board.id)

    socket =
      socket
      |> assign(:page_title, "Throughput Metrics")
      |> assign(:board, board)
      |> assign(:user_access, user_access)
      |> assign(:agents, agents)
      |> load_throughput_data()

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
      |> load_throughput_data()

    {:noreply, socket}
  end

  @impl true
  def handle_event("export_pdf", _params, socket) do
    {:noreply, put_flash(socket, :info, "PDF export feature coming soon!")}
  end

  defp load_throughput_data(socket) do
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

    {:ok, throughput} = Metrics.get_throughput(socket.assigns.board.id, opts)
    stats = calculate_summary_stats(throughput)

    socket
    |> assign(:throughput, throughput)
    |> assign(:summary_stats, stats)
    |> assign(:tasks, [])
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

  defp format_date(nil), do: "N/A"

  defp format_date(date) do
    Calendar.strftime(date, "%b %d, %Y")
  end

  defp calculate_bar_width(_count, 0), do: 0
  defp calculate_bar_width(0, _peak), do: 0

  defp calculate_bar_width(count, peak) when count > 0 and peak > 0 do
    (count / peak * 100) |> Float.round(1)
  end
end
