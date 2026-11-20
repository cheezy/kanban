defmodule KanbanWeb.API.Me.AgentController do
  @moduledoc """
  The app's Agents tab (W2761, docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md
  §6.10, §7.10):

    * `GET /api/me/agents` returns the roster `/agents` shows and the open
      goals its agents work on now, with each goal's task counts, which never
      count the goal itself (`Kanban.Agents.list_agents_for_app/2`);
    * `GET /api/me/goals/:id/after_goal` returns a goal's last `after_goal`
      attempt: its exit code, duration and report time, never its output
      (`Kanban.Tasks.AfterGoalAttempt.last/1`, decision 9).

  It runs behind the `:device_api` pipeline, so `:current_scope` and
  `:current_device` come from `KanbanWeb.Plugs.AuthenticateDeviceToken`. The
  roster's "today" counts are taken in the device's time zone, else UTC.
  Both routes are plan-gated with `:mobile_app` (design §10): the person's
  plan first. The roster then leaves out every board outside the plan; the
  after_goal read finds the goal as the web finds its board (404 for a goal on
  a board the person holds no access to, and for an id that is not a goal's)
  and only then checks the board's plan, so a `plan_required` answer never
  reveals a goal the person cannot see.

  Every refusal is rendered by `KanbanWeb.API.Me.FallbackController`.
  """
  use KanbanWeb, :controller

  alias Kanban.Agents
  alias Kanban.Plans
  alias Kanban.Tasks
  alias KanbanWeb.IdParams

  action_fallback KanbanWeb.API.Me.FallbackController

  def index(conn, _params) do
    %{current_scope: scope, current_device: device} = conn.assigns

    with :ok <- check_user(scope) do
      render(conn, :index,
        overview: Agents.list_agents_for_app(scope, timezone: time_zone(device))
      )
    end
  end

  def after_goal(conn, %{"id" => id}) do
    %{current_scope: scope} = conn.assigns

    with :ok <- check_user(scope),
         {:ok, goal_id} <- parse_id(id),
         {:ok, goal, board} <- Tasks.get_goal_for_app(scope, goal_id),
         :ok <- Plans.check_board(board, :mobile_app, surface: :controller) do
      render(conn, :after_goal, goal: goal)
    end
  end

  defp check_user(scope), do: Plans.check_user(scope, :mobile_app, surface: :controller)

  defp time_zone(%{time_zone: zone}) when is_binary(zone), do: zone
  defp time_zone(_device), do: nil

  defp parse_id(id) do
    case IdParams.parse(id) do
      {:ok, goal_id} -> {:ok, goal_id}
      :error -> {:error, :not_found}
    end
  end
end
