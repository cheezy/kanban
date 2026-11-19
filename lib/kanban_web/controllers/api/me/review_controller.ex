defmodule KanbanWeb.API.Me.ReviewController do
  @moduledoc """
  One pending review for the app's review screen (W2751,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §6.4, §7.5):
  `GET /api/me/reviews/:task_id`.

  It runs behind the `:device_api` pipeline, so `:current_scope` and
  `:current_device` come from `KanbanWeb.Plugs.AuthenticateDeviceToken`.
  The route is plan-gated with `:mobile_app` (design §10): the person's plan
  is checked first, then the task's board, and the board check runs only
  once the person is known to be able to review the task, so a
  `plan_required` answer never reveals a task they cannot see.

  A task that is not pending review, is on a board the person cannot write
  to, or an id that is not one, answers 404. `approvable_here` is computed
  for the requesting device's class. The data comes from
  `Kanban.Reviews.get_reviewable_task/2` and `Kanban.Reviews.mobile_review/2`.
  """
  use KanbanWeb, :controller

  alias Kanban.Plans
  alias Kanban.Reviews
  alias KanbanWeb.IdParams

  action_fallback KanbanWeb.API.Me.FallbackController

  def show(conn, %{"task_id" => task_id}) do
    %{current_scope: scope, current_device: device} = conn.assigns

    with {:ok, task} <- fetch_reviewable(scope, task_id) do
      render(conn, :show, review: Reviews.mobile_review(task, device.device_class))
    end
  end

  # The person's plan first, then their right to review the task, and only
  # then the task's board, so a 403 never says that a task exists.
  defp fetch_reviewable(scope, task_id) do
    with :ok <- Plans.check_user(scope, :mobile_app, surface: :controller),
         {:ok, id} <- parse_id(task_id),
         {:ok, task} <- Reviews.get_reviewable_task(scope, id),
         :ok <- Plans.check_board(task.column.board, :mobile_app, surface: :controller) do
      {:ok, task}
    end
  end

  defp parse_id(id) do
    case IdParams.parse(id) do
      {:ok, task_id} -> {:ok, task_id}
      :error -> {:error, :not_found}
    end
  end
end
