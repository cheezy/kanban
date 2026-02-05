defmodule KanbanWeb.Telemetry.UserActivityPage do
  @moduledoc """
  Custom LiveDashboard page showing user activity from telemetry events.
  Displays which users (by email) are using the API and what actions they're taking.
  """
  use Phoenix.LiveDashboard.PageBuilder

  import Ecto.Query
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

    sort_column = build_sort_column(sort_by)
    sort_direction = build_sort_direction(sort_dir)

    results = query_user_activity(search, sort_column, sort_direction, limit)
    total = query_user_count(search)

    {results, total}
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

  defp query_user_activity(search, sort_column, sort_direction, limit) do
    base_query =
      from me in "metrics_events",
        join: u in "users",
        on: fragment("CAST(? AS INTEGER)", me.metadata["user_id"]) == u.id,
        where: like(me.metric_name, "kanban.api.task_%"),
        where: not is_nil(fragment("?->>'user_id'", me.metadata)),
        group_by: [u.id, u.email],
        select: %{
          email: u.email,
          user_id: u.id,
          total_actions: count(me.id),
          tasks_claimed:
            fragment(
              "COUNT(*) FILTER (WHERE ? LIKE 'kanban.api.task_claimed%')",
              me.metric_name
            ),
          tasks_completed:
            fragment(
              "COUNT(*) FILTER (WHERE ? LIKE 'kanban.api.task_completed%')",
              me.metric_name
            ),
          tasks_created:
            fragment(
              "COUNT(*) FILTER (WHERE ? LIKE 'kanban.api.task_created%')",
              me.metric_name
            ),
          last_activity: max(me.recorded_at)
        },
        limit: ^limit

    query = apply_search_filter(base_query, search)
    query = apply_sort(query, sort_column, sort_direction)

    Repo.all(query)
  end

  defp query_user_count(search) do
    base_query =
      from me in "metrics_events",
        join: u in "users",
        on: fragment("CAST(? AS INTEGER)", me.metadata["user_id"]) == u.id,
        where: like(me.metric_name, "kanban.api.task_%"),
        where: not is_nil(fragment("?->>'user_id'", me.metadata)),
        select: count(u.id, :distinct)

    query = apply_search_filter(base_query, search)

    Repo.one(query) || 0
  end

  defp apply_search_filter(query, nil), do: query

  defp apply_search_filter(query, search) do
    from [me, u] in query,
      where: ilike(u.email, ^"%#{search}%")
  end

  defp apply_sort(query, :email, :asc) do
    from [me, u] in query, order_by: [asc: u.email]
  end

  defp apply_sort(query, :email, _) do
    from [me, u] in query, order_by: [desc: u.email]
  end

  defp apply_sort(query, :total_actions, :asc) do
    from [me, u] in query, order_by: [asc: count(me.id)]
  end

  defp apply_sort(query, :total_actions, _) do
    from [me, u] in query, order_by: [desc: count(me.id)]
  end

  defp apply_sort(query, :tasks_claimed, :asc) do
    from [me, u] in query,
      order_by: [
        asc:
          fragment(
            "COUNT(*) FILTER (WHERE ? LIKE 'kanban.api.task_claimed%')",
            me.metric_name
          )
      ]
  end

  defp apply_sort(query, :tasks_claimed, _) do
    from [me, u] in query,
      order_by: [
        desc:
          fragment(
            "COUNT(*) FILTER (WHERE ? LIKE 'kanban.api.task_claimed%')",
            me.metric_name
          )
      ]
  end

  defp apply_sort(query, :tasks_completed, :asc) do
    from [me, u] in query,
      order_by: [
        asc:
          fragment(
            "COUNT(*) FILTER (WHERE ? LIKE 'kanban.api.task_completed%')",
            me.metric_name
          )
      ]
  end

  defp apply_sort(query, :tasks_completed, _) do
    from [me, u] in query,
      order_by: [
        desc:
          fragment(
            "COUNT(*) FILTER (WHERE ? LIKE 'kanban.api.task_completed%')",
            me.metric_name
          )
      ]
  end

  defp apply_sort(query, :tasks_created, :asc) do
    from [me, u] in query,
      order_by: [
        asc:
          fragment(
            "COUNT(*) FILTER (WHERE ? LIKE 'kanban.api.task_created%')",
            me.metric_name
          )
      ]
  end

  defp apply_sort(query, :tasks_created, _) do
    from [me, u] in query,
      order_by: [
        desc:
          fragment(
            "COUNT(*) FILTER (WHERE ? LIKE 'kanban.api.task_created%')",
            me.metric_name
          )
      ]
  end

  defp apply_sort(query, _, _) do
    # Default to total_actions descending
    from [me, u] in query, order_by: [desc: count(me.id)]
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
