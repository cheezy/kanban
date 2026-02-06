defmodule KanbanWeb.MetricsLive.WaitTime do
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
      |> assign(:page_title, "Wait Time Metrics")
      |> assign(:board, board)
      |> assign(:user_access, user_access)
      |> assign(:agents, agents)
      |> assign(:time_range, time_range)
      |> assign(:agent_name, agent_name)
      |> assign(:exclude_weekends, exclude_weekends)
      |> load_wait_time_data()

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
      |> load_wait_time_data()

    {:noreply, socket}
  end

  @impl true
  def handle_event("export_pdf", _params, socket) do
    {:noreply, put_flash(socket, :info, "PDF export feature coming soon!")}
  end

  defp load_wait_time_data(socket) do
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

    {:ok, stats} = Metrics.get_wait_time_stats(socket.assigns.board.id, opts)
    review_tasks = get_review_wait_tasks(socket.assigns.board.id, opts)
    backlog_tasks = get_backlog_wait_tasks(socket.assigns.board.id, opts)

    socket
    |> assign(:review_wait_stats, stats.review_wait)
    |> assign(:backlog_wait_stats, stats.backlog_wait)
    |> assign(:review_tasks, review_tasks)
    |> assign(:backlog_tasks, backlog_tasks)
  end

  defp get_review_wait_tasks(board_id, opts) do
    time_range = Keyword.get(opts, :time_range, :last_30_days)
    agent_name = Keyword.get(opts, :agent_name)
    start_date = get_start_date(time_range)

    query =
      Task
      |> join(:inner, [t], c in assoc(t, :column))
      |> where([t, c], c.board_id == ^board_id)
      |> where([t], not is_nil(t.completed_at))
      |> where([t], not is_nil(t.reviewed_at))
      |> where([t], t.completed_at >= ^start_date)
      |> order_by([t], desc: t.reviewed_at)
      |> select([t], %{
        id: t.id,
        identifier: t.identifier,
        title: t.title,
        completed_at: t.completed_at,
        reviewed_at: t.reviewed_at,
        completed_by_agent: t.completed_by_agent,
        review_wait_seconds:
          fragment(
            "EXTRACT(EPOCH FROM (? - ?))",
            t.reviewed_at,
            t.completed_at
          )
      })

    query =
      if agent_name do
        where(query, [t], t.completed_by_agent == ^agent_name)
      else
        query
      end

    Repo.all(query)
  end

  defp get_backlog_wait_tasks(board_id, opts) do
    time_range = Keyword.get(opts, :time_range, :last_30_days)
    agent_name = Keyword.get(opts, :agent_name)
    start_date = get_start_date(time_range)

    query =
      Task
      |> join(:inner, [t], c in assoc(t, :column))
      |> where([t, c], c.board_id == ^board_id)
      |> where([t], not is_nil(t.claimed_at))
      |> where([t], t.inserted_at >= ^start_date)
      |> order_by([t], desc: t.claimed_at)
      |> select([t], %{
        id: t.id,
        identifier: t.identifier,
        title: t.title,
        inserted_at: t.inserted_at,
        claimed_at: t.claimed_at,
        completed_by_agent: t.completed_by_agent,
        backlog_wait_seconds:
          fragment(
            "EXTRACT(EPOCH FROM (? - ?))",
            t.claimed_at,
            t.inserted_at
          )
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
  defp get_start_date(_), do: DateTime.add(DateTime.utc_now(), -30, :day)

  defp format_wait_time(seconds) when is_number(seconds) do
    hours = seconds / 3600

    cond do
      hours < 1 -> "#{Float.round(hours * 60, 1)}m"
      hours < 24 -> "#{Float.round(hours, 1)}h"
      true -> "#{Float.round(hours / 24, 1)}d"
    end
  end

  defp format_wait_time(_), do: "N/A"

  defp format_datetime(nil), do: "N/A"

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y %I:%M %p")
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
