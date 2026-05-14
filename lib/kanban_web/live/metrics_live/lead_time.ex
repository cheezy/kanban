defmodule KanbanWeb.MetricsLive.LeadTime do
  use KanbanWeb, :live_view
  use KanbanWeb.MetricsLive.Base, page_title: "Lead Time Metrics"

  import Ecto.Query
  import KanbanWeb.MetricsLive.Components

  alias Kanban.Metrics
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias KanbanWeb.MetricsLive.Helpers

  @impl KanbanWeb.MetricsLive.Base
  def load_data(socket) do
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

    {:ok, stats} = Metrics.get_lead_time_stats(socket.assigns.board.id, opts)
    tasks = get_lead_time_tasks(socket.assigns.board.id, opts)
    grouped_tasks = group_tasks_by_date(tasks)
    daily_lead_times = calculate_daily_lead_times(tasks)

    socket
    |> assign(:summary_stats, stats)
    |> assign(:tasks, tasks)
    |> assign(:grouped_tasks, grouped_tasks)
    |> assign(:daily_lead_times, daily_lead_times)
  end

  defp get_lead_time_tasks(board_id, opts) do
    time_range = Keyword.get(opts, :time_range, :last_30_days)
    agent_name = Keyword.get(opts, :agent_name)
    start_date = Helpers.get_start_date(time_range)

    query =
      Task
      |> join(:inner, [t], c in assoc(t, :column))
      |> where([t, c], c.board_id == ^board_id)
      |> where([t], not is_nil(t.completed_at))
      |> where([t], t.completed_at >= ^start_date)
      |> where([t], t.type != ^:goal)
      |> order_by([t], desc: t.completed_at)
      |> select([t], %{
        id: t.id,
        identifier: t.identifier,
        title: t.title,
        inserted_at: t.inserted_at,
        completed_at: t.completed_at,
        completed_by_agent: t.completed_by_agent,
        lead_time_seconds:
          fragment(
            "EXTRACT(EPOCH FROM (? - ?))",
            t.completed_at,
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

  # Used in lead_time.html.heex (analyzer does not scan HEEx files).
  defp format_lead_time(seconds), do: Helpers.format_time(seconds)
  defp format_lead_time_hours(hours), do: Helpers.format_time_hours(hours)
  defp format_datetime(datetime), do: Helpers.format_datetime(datetime)

  defp group_tasks_by_date(tasks), do: Helpers.group_tasks_by_completion_date(tasks)

  defp calculate_daily_lead_times(tasks) do
    Helpers.calculate_daily_times(tasks, :lead_time_seconds)
  end
end
