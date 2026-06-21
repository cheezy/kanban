defmodule KanbanWeb.MetricsLive.WaitTime do
  use KanbanWeb, :live_view
  use KanbanWeb.MetricsLive.Base, page_title: "Wait Time Metrics"

  import Ecto.Query
  import KanbanWeb.MetricsLive.Components

  alias Kanban.Metrics
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskHistory
  alias Kanban.Timezone
  alias KanbanWeb.MetricsLive.Helpers

  @impl KanbanWeb.MetricsLive.Base
  def load_data(socket) do
    opts = build_wait_time_opts(socket)
    board_id = socket.assigns.board.id

    {:ok, stats} = Metrics.get_wait_time_stats(board_id, opts)
    review_tasks = get_review_wait_tasks(board_id, opts)
    backlog_tasks = get_backlog_wait_tasks(board_id, opts)

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

  defp get_review_wait_tasks(board_id, opts) do
    board = Repo.get!(Kanban.Boards.Board, board_id)

    if board.ai_optimized_board do
      get_review_wait_tasks_ai(board_id, opts)
    else
      []
    end
  end

  defp get_review_wait_tasks_ai(board_id, opts) do
    time_range = Keyword.get(opts, :time_range, :last_30_days)
    agent_name = Keyword.get(opts, :agent_name)
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")
    start_date = Helpers.get_start_date(time_range, timezone)

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
            "GREATEST(0, EXTRACT(EPOCH FROM (? - ?)))",
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
    board = Repo.get!(Kanban.Boards.Board, board_id)

    if board.ai_optimized_board do
      get_backlog_wait_tasks_ai(board_id, opts)
    else
      get_backlog_wait_tasks_regular(board_id, opts)
    end
  end

  defp get_backlog_wait_tasks_ai(board_id, opts) do
    time_range = Keyword.get(opts, :time_range, :last_30_days)
    agent_name = Keyword.get(opts, :agent_name)
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")
    start_date = Helpers.get_start_date(time_range, timezone)

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
            "GREATEST(0, EXTRACT(EPOCH FROM (? - ?)))",
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

  defp get_backlog_wait_tasks_regular(board_id, opts) do
    time_range = Keyword.get(opts, :time_range, :last_30_days)
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")
    start_date = Helpers.get_start_date(time_range, timezone)

    first_move_subquery =
      from th in TaskHistory,
        where: th.type == :move,
        group_by: th.task_id,
        select: %{task_id: th.task_id, first_moved_at: min(th.inserted_at)}

    Task
    |> join(:inner, [t], c in assoc(t, :column))
    |> join(:inner, [t], fm in subquery(first_move_subquery), on: fm.task_id == t.id)
    |> where([t, c], c.board_id == ^board_id)
    |> where([t], t.type != ^:goal)
    |> order_by([t, _c, fm], desc: fm.first_moved_at)
    |> where([t, _c, fm], fm.first_moved_at >= ^start_date)
    |> select([t, _c, fm], %{
      id: t.id,
      identifier: t.identifier,
      title: t.title,
      inserted_at: t.inserted_at,
      claimed_at: fm.first_moved_at,
      completed_by_agent: t.completed_by_agent,
      backlog_wait_seconds:
        fragment(
          "GREATEST(0, EXTRACT(EPOCH FROM (? - ?)))",
          fm.first_moved_at,
          t.inserted_at
        )
    })
    |> Repo.all()
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
