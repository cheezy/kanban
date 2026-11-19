defmodule KanbanWeb.API.Me.ReviewController do
  @moduledoc """
  One pending review for the app's review screen (W2751,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §6.4, §7.5):
  `GET /api/me/reviews/:task_id`.

  `GET /api/me/reviews` (W2758, design §7.5) is the review queue: only the
  `review` items of `GET /api/me/decisions`, in the same order, from
  `Kanban.Decisions.review_queue/2`. It checks the person's plan only: a
  board outside the plan never contributes a review item.

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

  `GET /api/me/reviews/:task_id/files/:index` (W2753, design §6.5) returns
  one file's highlighted diff and inline notes, from
  `Kanban.Reviews.mobile_review_file/2`, after the same checks as the detail.
  `index` is the file's `index` in the detail; one that is not a
  non-negative integer, or names no file of this task, answers 404.

  The app approves a review in two requests (W2754, design §6.6, §7.5),
  both run by `Kanban.Reviews.Approval`:

    * `POST /api/me/reviews/:task_id/approval_challenge` issues a single-use
      nonce, valid for 2 minutes, for this device, task and
      `review_requested_at`;
    * `POST /api/me/reviews/:task_id/approve` takes `review_requested_at`, the
      nonce and the device's signature and, once the five checks pass in the
      documented order, approves through `Kanban.Reviews.approve_review/3`.

  The app asks for changes in one request (W2755, design §7.5), run by
  `Kanban.Reviews.RequestChanges`:

    * `POST /api/me/reviews/:task_id/request_changes` takes
      `review_requested_at` and `notes` (required) and, once checks 1 to 3
      of the approval pass, requests changes through
      `Kanban.Reviews.request_changes_review/3`. There is no signature and
      no large-change guard: a phone may ask for changes on any change.

  All three count against the device's `:review_approval` rate limit
  (`Kanban.RateLimit`) before anything is looked up, and answer `429` with
  `retry-after` once it is reached.

  `approve` and `request_changes` take an optional `Idempotency-Key` header
  (`KanbanWeb.API.Me.Idempotent`): a retry with the same key within 24 hours
  is answered with the first successful result instead of a 409.

  Every refusal is rendered by `KanbanWeb.API.Me.FallbackController`.
  """
  use KanbanWeb, :controller

  alias Kanban.Decisions
  alias Kanban.Plans
  alias Kanban.RateLimit
  alias Kanban.Reviews
  alias Kanban.Reviews.Approval
  alias Kanban.Reviews.DecisionChecks
  alias Kanban.Reviews.RequestChanges
  alias KanbanWeb.API.Me.Idempotent
  alias KanbanWeb.API.Me.ReviewJSON
  alias KanbanWeb.IdParams

  action_fallback KanbanWeb.API.Me.FallbackController

  def index(conn, _params) do
    %{current_scope: scope} = conn.assigns

    with :ok <- Plans.check_user(scope, :mobile_app, surface: :controller) do
      render(conn, :index, items: Decisions.review_queue(scope, source: :api))
    end
  end

  def show(conn, %{"task_id" => task_id}) do
    %{current_scope: scope, current_device: device} = conn.assigns

    with {:ok, task} <- fetch_reviewable(scope, task_id) do
      render(conn, :show, review: Reviews.mobile_review(task, device.device_class))
    end
  end

  def file(conn, %{"task_id" => task_id, "index" => index}) do
    %{current_scope: scope} = conn.assigns

    with {:ok, task} <- fetch_reviewable(scope, task_id),
         {:ok, index} <- parse_index(index),
         {:ok, file} <- Reviews.mobile_review_file(task, index) do
      render(conn, :file_diff, file: file)
    end
  end

  def approval_challenge(conn, %{"task_id" => task_id}) do
    %{current_scope: scope, current_device: device} = conn.assigns

    with :ok <- approval_rate_limit(device),
         {:ok, id} <- parse_id(task_id),
         {:ok, challenge, task} <- Approval.issue_challenge(scope, device, id, conn.body_params) do
      conn
      |> put_status(:created)
      |> render(:challenge, challenge: challenge, task: task)
    end
  end

  def approve(conn, %{"task_id" => task_id}) do
    render = &ReviewJSON.approved(%{task: &1})

    decide(conn, task_id, :approve, render, fn scope, device, id, idempotency ->
      Approval.approve(scope, device, id, conn.body_params, DateTime.utc_now(),
        idempotency: idempotency
      )
    end)
  end

  def request_changes(conn, %{"task_id" => task_id}) do
    render = &ReviewJSON.changes_requested(%{task: &1})

    decide(conn, task_id, :request_changes, render, fn scope, device, id, idempotency ->
      RequestChanges.request_changes(scope, device, id, conn.body_params,
        idempotency: idempotency
      )
    end)
  end

  # Both decisions: the shared rate limit, the task id and the Idempotency-Key,
  # then `decision` (or the stored result, once `DecisionChecks.replayable/2`
  # allows it) through `Idempotent.run/5`.
  defp decide(conn, task_id, action, render, decision) do
    %{current_device: device} = conn.assigns

    with :ok <- approval_rate_limit(device),
         {:ok, id} <- parse_id(task_id),
         {:ok, key} <- Idempotent.key(conn, device, action, id, render),
         do: run_decision(conn, key, render, id, decision)
  end

  defp run_decision(conn, key, render, id, decision) do
    %{current_scope: scope, current_device: device} = conn.assigns

    Idempotent.run(
      conn,
      key,
      render,
      &decision.(scope, device, id, &1),
      fn -> DecisionChecks.replayable(scope, id) end
    )
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

  defp approval_rate_limit(%{id: device_id}),
    do: RateLimit.check(:review_approval, identity: "device:#{device_id}")

  defp parse_index(index) do
    case IdParams.parse_index(index) do
      {:ok, index} -> {:ok, index}
      :error -> {:error, :not_found}
    end
  end

  defp parse_id(id) do
    case IdParams.parse(id) do
      {:ok, task_id} -> {:ok, task_id}
      :error -> {:error, :not_found}
    end
  end
end
