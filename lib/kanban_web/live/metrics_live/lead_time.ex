defmodule KanbanWeb.MetricsLive.LeadTime do
  use KanbanWeb, :live_view
  use KanbanWeb.MetricsLive.Base, page_title: "Lead Time Metrics"

  import Ecto.Query
  import KanbanWeb.MetricsLive.Components

  alias Kanban.Metrics
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias KanbanWeb.MetricsLive.Base
  alias KanbanWeb.MetricsLive.Helpers

  @impl KanbanWeb.MetricsLive.Base
  def load_data(socket) do
    Base.load_metric_data(
      socket,
      &Metrics.get_lead_time_stats/2,
      &get_lead_time_tasks/2,
      :lead_time_seconds,
      :daily_lead_times
    )
  end

  defp get_lead_time_tasks(board_id, opts) do
    time_range = Keyword.get(opts, :time_range, :last_30_days)
    agent_name = Keyword.get(opts, :agent_name)
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")
    start_date = Helpers.get_start_date(time_range, timezone)

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
end
