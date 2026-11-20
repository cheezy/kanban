defmodule KanbanWeb.API.Me.GoalController do
  @moduledoc """
  The app's Goals list and Goal screen (W2762,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §6.18, §6.19, §7.10):

    * `GET /api/me/goals` returns one page of the goals on every board the
      person can see, across their workspaces, newest first, 100 per page,
      with the `filter` param `open` (the default), `done` or `no_target`
      (`Kanban.Tasks.list_goals_for_app/2`);
    * `GET /api/me/goals/:id` returns a goal with its tasks grouped by
      column, its counts and `archived_done`
      (`Kanban.Tasks.get_goal_detail_for_app/3`).

  It runs behind the `:device_api` pipeline, so `:current_scope` and
  `:current_device` come from `KanbanWeb.Plugs.AuthenticateDeviceToken`. Both
  routes are plan-gated with `:mobile_app` (design §10): the person's plan
  first. The list then leaves out every board outside the plan; the goal read
  finds the goal as the web finds its board (404 for a goal on a board the
  person holds no access to, and for an id that is not a goal's) and only
  then checks the board's plan, so a `plan_required` answer never reveals a
  goal the person cannot see. On the list, an unknown `filter` is checked
  before `page`.

  A read that answers 200 emits `[:kanban, :status, :viewed]` with its
  `surface` (`:goals` or `:goal`) and `via`, the device's platform.

  Every refusal is rendered by `KanbanWeb.API.Me.FallbackController`.
  """
  use KanbanWeb, :controller

  alias Kanban.Plans
  alias Kanban.Tasks
  alias KanbanWeb.API.Me.PageParams
  alias KanbanWeb.IdParams

  action_fallback KanbanWeb.API.Me.FallbackController

  def index(conn, params) do
    %{current_scope: scope, current_device: device} = conn.assigns

    with :ok <- check_user(scope),
         {:ok, filter} <- params |> Map.get("filter") |> Tasks.parse_goal_filter(),
         {:ok, page} <- PageParams.parse(params) do
      result = Tasks.list_goals_for_app(scope, filter: filter, page: page)
      viewed(:goals, device)
      render(conn, :index, result: result)
    end
  end

  def show(conn, %{"id" => id}) do
    %{current_scope: scope, current_device: device} = conn.assigns

    with :ok <- check_user(scope),
         {:ok, goal, board} <- fetch_goal(scope, id) do
      detail = Tasks.get_goal_detail_for_app(scope, goal, board)
      viewed(:goal, device)
      render(conn, :show, detail: detail)
    end
  end

  # The goal is found before its board's plan is checked, so a 403 never
  # reveals a goal the person cannot see.
  defp fetch_goal(scope, id) do
    with {:ok, goal_id} <- parse_id(id),
         {:ok, goal, board} <- Tasks.get_goal_for_app(scope, goal_id),
         :ok <- Plans.check_board(board, :mobile_app, surface: :controller) do
      {:ok, goal, board}
    end
  end

  defp check_user(scope), do: Plans.check_user(scope, :mobile_app, surface: :controller)

  defp viewed(surface, device) do
    Kanban.Telemetry.emit([:kanban, :status, :viewed], %{count: 1}, %{
      surface: surface,
      via: device.platform
    })
  end

  defp parse_id(id) do
    case IdParams.parse(id) do
      {:ok, goal_id} -> {:ok, goal_id}
      :error -> {:error, :not_found}
    end
  end
end
