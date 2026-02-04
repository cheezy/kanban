defmodule KanbanWeb.Telemetry.UserActivityPage do
  @moduledoc """
  Custom LiveDashboard page showing user activity from telemetry events.
  Displays which users (by email) are using the API and what actions they're taking.
  """
  use Phoenix.LiveDashboard.PageBuilder

  alias Kanban.Repo

  @impl true
  def menu_link(_, _) do
    {:ok, "User Activity"}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_table
      id="user-activity-table"
      dom_id="user-activity-table"
      page={@page}
      title="API User Activity"
      row_fetcher={&fetch_user_activity/2}
      row_attrs={&row_attrs/1}
      rows_name="users"
    >
      <:col field={:email} header="User Email" sortable={:asc} />
      <:col field={:user_id} header="User ID" />
      <:col field={:total_actions} header="Total Actions" text_align="right" sortable={:desc} />
      <:col field={:tasks_claimed} header="Tasks Claimed" text_align="right" sortable={:desc} />
      <:col field={:tasks_completed} header="Tasks Completed" text_align="right" sortable={:desc} />
      <:col field={:tasks_created} header="Tasks Created" text_align="right" sortable={:desc} />
      <:col field={:last_activity} header="Last Activity" :let={user}>
        <%= format_datetime(user[:last_activity]) %>
      </:col>
    </.live_table>
    """
  end

  defp fetch_user_activity(params, _node) do
    %{search: search, sort_by: sort_by, sort_dir: sort_dir, limit: limit} = params

    search_clause = build_search_clause(search)
    sort_column = build_sort_column(sort_by)
    sort_direction = build_sort_direction(sort_dir)

    results = query_user_activity(search_clause, sort_column, sort_direction, limit)
    total = query_user_count(search_clause)

    {results, total}
  end

  defp build_search_clause(nil), do: ""

  defp build_search_clause(search) do
    "AND u.email ILIKE '%#{String.replace(search, "'", "''")}%'"
  end

  defp build_sort_column(sort_by) do
    case sort_by do
      :email -> "u.email"
      :total_actions -> "total_actions"
      :tasks_claimed -> "tasks_claimed"
      :tasks_completed -> "tasks_completed"
      :tasks_created -> "tasks_created"
      _ -> "total_actions"
    end
  end

  defp build_sort_direction(:asc), do: "ASC"
  defp build_sort_direction(_), do: "DESC"

  defp query_user_activity(search_clause, sort_column, sort_direction, limit) do
    sql = """
    SELECT
      u.email,
      u.id as user_id,
      COUNT(*) as total_actions,
      COUNT(*) FILTER (WHERE me.metric_name LIKE 'kanban.api.task_claimed%') as tasks_claimed,
      COUNT(*) FILTER (WHERE me.metric_name LIKE 'kanban.api.task_completed%') as tasks_completed,
      COUNT(*) FILTER (WHERE me.metric_name LIKE 'kanban.api.task_created%') as tasks_created,
      MAX(me.recorded_at) as last_activity
    FROM metrics_events me
    JOIN users u ON CAST(me.metadata->>'user_id' AS INTEGER) = u.id
    WHERE me.metric_name LIKE 'kanban.api.task_%'
      AND me.metadata->>'user_id' IS NOT NULL
      #{search_clause}
    GROUP BY u.id, u.email
    ORDER BY #{sort_column} #{sort_direction}
    LIMIT $1
    """

    result = Repo.query!(sql, [limit])

    Enum.map(result.rows, fn [email, user_id, total_actions, tasks_claimed, tasks_completed, tasks_created, last_activity] ->
      %{
        email: email,
        user_id: user_id,
        total_actions: total_actions,
        tasks_claimed: tasks_claimed,
        tasks_completed: tasks_completed,
        tasks_created: tasks_created,
        last_activity: last_activity
      }
    end)
  end

  defp query_user_count(search_clause) do
    sql = """
    SELECT COUNT(DISTINCT u.id)
    FROM metrics_events me
    JOIN users u ON CAST(me.metadata->>'user_id' AS INTEGER) = u.id
    WHERE me.metric_name LIKE 'kanban.api.task_%'
      AND me.metadata->>'user_id' IS NOT NULL
      #{search_clause}
    """

    Repo.query!(sql, []).rows |> List.first() |> List.first() |> then(&(&1 || 0))
  end

  defp row_attrs(user) do
    [
      {"phx-click", "show_details"},
      {"phx-value-user-id", user.user_id}
    ]
  end

  defp format_datetime(datetime) do
    case datetime do
      %DateTime{} = dt ->
        Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")

      %NaiveDateTime{} = ndt ->
        Calendar.strftime(ndt, "%Y-%m-%d %H:%M:%S")

      _ ->
        "N/A"
    end
  end
end
