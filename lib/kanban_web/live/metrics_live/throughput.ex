defmodule KanbanWeb.MetricsLive.Throughput do
  use KanbanWeb, :live_view

  import Ecto.Query

  alias Kanban.Boards
  alias Kanban.Metrics
  alias Kanban.Repo
  alias Kanban.Tasks.Task

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
    tasks = get_throughput_tasks(socket.assigns.board.id, opts)

    socket
    |> assign(:throughput, throughput)
    |> assign(:summary_stats, stats)
    |> assign(:tasks, tasks)
  end

  defp get_throughput_tasks(board_id, opts) do
    time_range = Keyword.get(opts, :time_range, :last_30_days)
    agent_name = Keyword.get(opts, :agent_name)
    start_date = get_start_date(time_range)

    query =
      Task
      |> join(:inner, [t], c in assoc(t, :column))
      |> where([t, c], c.board_id == ^board_id)
      |> where([t], not is_nil(t.completed_at))
      |> where([t], t.completed_at >= ^start_date)
      |> order_by([t], desc: t.completed_at)
      |> select([t], %{
        id: t.id,
        identifier: t.identifier,
        title: t.title,
        inserted_at: t.inserted_at,
        claimed_at: t.claimed_at,
        completed_at: t.completed_at,
        completed_by_agent: t.completed_by_agent
      })

    query =
      if agent_name do
        where(query, [t], t.completed_by_agent == ^agent_name)
      else
        query
      end

    Repo.all(query)
  end

  defp get_start_date(:today) do
    DateTime.utc_now()
    |> DateTime.to_date()
    |> DateTime.new!(~T[00:00:00])
  end

  defp get_start_date(:last_7_days), do: DateTime.add(DateTime.utc_now(), -7, :day)
  defp get_start_date(:last_30_days), do: DateTime.add(DateTime.utc_now(), -30, :day)
  defp get_start_date(:last_90_days), do: DateTime.add(DateTime.utc_now(), -90, :day)
  defp get_start_date(:all_time), do: ~U[2020-01-01 00:00:00Z]

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

  defp format_datetime(nil), do: "N/A"

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y %I:%M %p")
  end

  defp calculate_bar_width(_count, 0), do: 0
  defp calculate_bar_width(0, _peak), do: 0

  defp calculate_bar_width(count, peak) when count > 0 and peak > 0 do
    (count / peak * 100) |> Float.round(1)
  end
end
