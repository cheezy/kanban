defmodule KanbanWeb.MetricsLive.WaitTime do
  use KanbanWeb, :live_view

  import Ecto.Query
  import KanbanWeb.MetricsLive.Components

  alias Kanban.Boards
  alias Kanban.Metrics
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias KanbanWeb.MetricsLive.Helpers

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

    if board.ai_optimized_board do
      {:ok, agents} = Metrics.get_agents(board.id)

      time_range = Helpers.parse_time_range(params["time_range"])
      agent_name = Helpers.parse_agent_name(params["agent_name"])
      exclude_weekends = Helpers.parse_exclude_weekends(params["exclude_weekends"])

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
    else
      socket =
        socket
        |> put_flash(:error, "Metrics are only available for AI-optimized boards.")
        |> redirect(to: ~p"/boards/#{board}")

      {:noreply, socket}
    end
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
    grouped_review_tasks = group_review_tasks_by_date(review_tasks)
    grouped_backlog_tasks = group_backlog_tasks_by_date(backlog_tasks)

    socket
    |> assign(:review_wait_stats, stats.review_wait)
    |> assign(:backlog_wait_stats, stats.backlog_wait)
    |> assign(:review_tasks, review_tasks)
    |> assign(:backlog_tasks, backlog_tasks)
    |> assign(:grouped_review_tasks, grouped_review_tasks)
    |> assign(:grouped_backlog_tasks, grouped_backlog_tasks)
  end

  defp get_review_wait_tasks(board_id, opts) do
    time_range = Keyword.get(opts, :time_range, :last_30_days)
    agent_name = Keyword.get(opts, :agent_name)
    start_date = Helpers.get_start_date(time_range)

    query =
      Task
      |> join(:inner, [t], c in assoc(t, :column))
      |> where([t, c], c.board_id == ^board_id)
      |> where([t], not is_nil(t.completed_at))
      |> where([t], not is_nil(t.reviewed_at))
      |> where([t], t.reviewed_at >= ^start_date)
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
    start_date = Helpers.get_start_date(time_range)

    query =
      Task
      |> join(:inner, [t], c in assoc(t, :column))
      |> where([t, c], c.board_id == ^board_id)
      |> where([t], not is_nil(t.claimed_at))
      |> where([t], t.claimed_at >= ^start_date)
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

  defp format_wait_time(seconds), do: Helpers.format_time(seconds)
  defp format_datetime(datetime), do: Helpers.format_datetime(datetime)
  defp format_date(date), do: Helpers.format_date(date)
  defp format_time(datetime), do: Helpers.format_time_only(datetime)

  defp group_review_tasks_by_date(tasks) do
    tasks
    |> Enum.group_by(fn task ->
      task.reviewed_at
      |> DateTime.to_date()
    end)
    |> Enum.sort_by(fn {date, _tasks} -> date end, {:desc, Date})
    |> Enum.map(fn {date, day_tasks} ->
      {date, Enum.sort_by(day_tasks, & &1.reviewed_at, {:desc, DateTime})}
    end)
  end

  defp group_backlog_tasks_by_date(tasks) do
    tasks
    |> Enum.group_by(fn task ->
      task.claimed_at
      |> DateTime.to_date()
    end)
    |> Enum.sort_by(fn {date, _tasks} -> date end, {:desc, Date})
    |> Enum.map(fn {date, day_tasks} ->
      {date, Enum.sort_by(day_tasks, & &1.claimed_at, {:desc, DateTime})}
    end)
  end
end
