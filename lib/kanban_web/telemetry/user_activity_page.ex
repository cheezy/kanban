defmodule KanbanWeb.Telemetry.UserActivityPage do
  @moduledoc """
  Custom LiveDashboard page showing user activity from telemetry events.
  Displays which users (by email) are using the API and what actions they're taking.
  """
  use Phoenix.LiveDashboard.PageBuilder

  alias Kanban.Metrics.UserActivity

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
      <:col :let={user} field={:last_activity} header="Last Activity">
        {format_datetime(user[:last_activity])}
      </:col>
    </.live_table>
    """
  end

  @impl true
  def handle_event("show_details", %{"user-id" => _user_id}, socket) do
    {:noreply, socket}
  end

  defp fetch_user_activity(params, _node) do
    %{search: search, sort_by: sort_by, sort_dir: sort_dir, limit: limit} = params

    opts = [search: search, sort_by: sort_by, sort_dir: sort_dir, limit: limit]

    {UserActivity.list_user_activity(opts), UserActivity.count_user_activity(opts)}
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
