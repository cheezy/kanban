defmodule KanbanWeb.MetricsLive.CycleTime do
  use KanbanWeb, :live_view
  use KanbanWeb.MetricsLive.Base, page_title: "Cycle Time Metrics"

  import Ecto.Query
  import KanbanWeb.MetricsLive.Components

  alias Kanban.Metrics
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskHistory
  alias KanbanWeb.MetricsLive.Base
  alias KanbanWeb.MetricsLive.Helpers

  @impl KanbanWeb.MetricsLive.Base
  def load_data(socket) do
    Base.load_metric_data(
      socket,
      &Metrics.get_cycle_time_stats/2,
      &get_cycle_time_tasks/2,
      :cycle_time_seconds,
      :daily_cycle_times
    )
  end

  defp get_cycle_time_tasks(board_id, opts) do
    board = Repo.get!(Kanban.Boards.Board, board_id)

    if board.ai_optimized_board do
      get_cycle_time_tasks_ai(board_id, opts)
    else
      get_cycle_time_tasks_regular(board_id, opts)
    end
  end

  defp get_cycle_time_tasks_ai(board_id, opts) do
    time_range = Keyword.get(opts, :time_range, :last_30_days)
    agent_name = Keyword.get(opts, :agent_name)
    start_date = Helpers.get_start_date(time_range)

    query =
      Task
      |> join(:inner, [t], c in assoc(t, :column))
      |> where([t, c], c.board_id == ^board_id)
      |> where([t], not is_nil(t.completed_at))
      |> where([t], not is_nil(t.claimed_at))
      |> where([t], t.completed_at >= ^start_date)
      |> where([t], t.type != ^:goal)
      |> order_by([t], desc: t.completed_at)
      |> select([t], %{
        id: t.id,
        identifier: t.identifier,
        title: t.title,
        claimed_at: t.claimed_at,
        completed_at: t.completed_at,
        completed_by_agent: t.completed_by_agent,
        cycle_time_seconds:
          fragment(
            "EXTRACT(EPOCH FROM (? - ?))",
            t.completed_at,
            t.claimed_at
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

  defp get_cycle_time_tasks_regular(board_id, opts) do
    time_range = Keyword.get(opts, :time_range, :last_30_days)
    start_date = Helpers.get_start_date(time_range)

    first_move_subquery =
      from th in TaskHistory,
        where: th.type == :move,
        group_by: th.task_id,
        select: %{task_id: th.task_id, started_at: min(th.inserted_at)}

    Task
    |> join(:inner, [t], c in assoc(t, :column))
    |> join(:inner, [t], fm in subquery(first_move_subquery), on: fm.task_id == t.id)
    |> where([t, c], c.board_id == ^board_id)
    |> where([t], not is_nil(t.completed_at))
    |> where([t], t.completed_at >= ^start_date)
    |> where([t], t.type != ^:goal)
    |> order_by([t], desc: t.completed_at)
    |> select([t, _c, fm], %{
      id: t.id,
      identifier: t.identifier,
      title: t.title,
      claimed_at: fm.started_at,
      completed_at: t.completed_at,
      completed_by_agent: t.completed_by_agent,
      cycle_time_seconds:
        fragment(
          "EXTRACT(EPOCH FROM (? - ?))",
          t.completed_at,
          fm.started_at
        )
    })
    |> Repo.all()
  end

  # Used in cycle_time.html.heex (analyzer does not scan HEEx files).
  defp format_cycle_time(seconds), do: Helpers.format_time(seconds)
  defp format_cycle_time_hours(hours), do: Helpers.format_time_hours(hours)
  defp format_datetime(datetime), do: Helpers.format_datetime(datetime)
end
