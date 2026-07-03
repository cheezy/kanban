defmodule KanbanWeb.MetricsLive.WaitTime do
  use KanbanWeb, :live_view
  use KanbanWeb.MetricsLive.Base, page_title: "Wait Time Metrics"

  import KanbanWeb.MetricsLive.Components

  alias Kanban.Metrics
  alias Kanban.Metrics.TaskQueries
  alias Kanban.Timezone
  alias KanbanWeb.MetricsLive.Helpers

  @impl KanbanWeb.MetricsLive.Base
  def load_data(socket) do
    opts = build_wait_time_opts(socket)
    board_id = socket.assigns.board.id

    {:ok, stats} = Metrics.get_wait_time_stats(board_id, opts)
    review_tasks = TaskQueries.get_review_wait_tasks(board_id, opts)
    backlog_tasks = TaskQueries.get_backlog_wait_tasks(board_id, opts)

    assign_wait_time_data(socket, stats, review_tasks, backlog_tasks)
  end

  defp assign_wait_time_data(socket, stats, review_tasks, backlog_tasks) do
    timezone = Map.get(socket.assigns, :timezone, "Etc/UTC")

    socket
    |> assign(:review_wait_stats, stats.review_wait)
    |> assign(:backlog_wait_stats, stats.backlog_wait)
    |> assign(:review_tasks, review_tasks)
    |> assign(:backlog_tasks, backlog_tasks)
    |> assign(:grouped_review_tasks, group_review_tasks_by_date(review_tasks, timezone))
    |> assign(:grouped_backlog_tasks, group_backlog_tasks_by_date(backlog_tasks, timezone))
  end

  defp build_wait_time_opts(socket) do
    opts = [
      time_range: socket.assigns.time_range,
      exclude_weekends: socket.assigns.exclude_weekends,
      timezone: Map.get(socket.assigns, :timezone, "Etc/UTC")
    ]

    if socket.assigns.agent_name do
      Keyword.put(opts, :agent_name, socket.assigns.agent_name)
    else
      opts
    end
  end

  # Used in wait_time.html.heex (analyzer does not scan HEEx files).
  defp format_wait_time(seconds), do: Helpers.format_time(seconds)
  defp format_datetime(datetime), do: Helpers.format_datetime(datetime)
  defp format_time(datetime), do: Helpers.format_time_only(datetime)

  defp group_review_tasks_by_date(tasks, timezone) do
    tasks
    |> Enum.group_by(fn task -> local_day(task.reviewed_at, timezone) end)
    |> Enum.sort_by(fn {date, _tasks} -> date end, {:desc, Date})
    |> Enum.map(fn {date, day_tasks} ->
      {date, Enum.sort_by(day_tasks, & &1.reviewed_at, {:desc, DateTime})}
    end)
  end

  defp group_backlog_tasks_by_date(tasks, timezone) do
    tasks
    |> Enum.group_by(fn task -> local_day(task.claimed_at, timezone) end)
    |> Enum.sort_by(fn {date, _tasks} -> date end, {:desc, Date})
    |> Enum.map(fn {date, day_tasks} ->
      {date, Enum.sort_by(day_tasks, & &1.claimed_at, :desc)}
    end)
  end

  # The viewer-local calendar date of a timestamp. Regular-board backlog rows
  # carry a NaiveDateTime (the first TaskHistory move, stored as UTC); AI-board
  # rows carry a UTC DateTime. Normalize the naive value to UTC first, then
  # shift into the viewer's zone via Kanban.Timezone.local_date/2.
  defp local_day(%DateTime{} = dt, timezone), do: Timezone.local_date(dt, timezone)

  defp local_day(%NaiveDateTime{} = ndt, timezone) do
    ndt |> DateTime.from_naive!("Etc/UTC") |> Timezone.local_date(timezone)
  end
end
