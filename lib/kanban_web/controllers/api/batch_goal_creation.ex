defmodule KanbanWeb.API.BatchGoalCreation do
  @moduledoc """
  Batch goal creation for `POST /api/tasks/batch`, extracted from
  `KanbanWeb.API.TaskController` (W1444).

  Processes a list of goal params one at a time, stopping on the first failure
  (`Enum.reduce_while`), and renders the documented batch response — the 201
  success shape, the 422 changeset shape (`error`/`index`/`details`), and the
  422 WIP-limit shape. The exact success/failure aggregation and response
  bodies are documented in `docs/api/post_tasks_batch.md` and matched by the
  request-test suite, so they must not drift.

  Like `KanbanWeb.API.TaskErrors`, this module takes `conn` and renders. It
  reuses the controller's shared creation/telemetry/rendering helpers
  (`build_task_params_with_creator/3`, `log_create_forbidden_fields/3`,
  `emit_telemetry/3`, `render_goal_with_children/1`, `render_task_summary/1`),
  which stay in `TaskController` because they are shared with the single-create
  and dependency-listing actions.
  """

  import Plug.Conn, only: [put_status: 2]
  import Phoenix.Controller, only: [json: 2]

  alias Kanban.Tasks
  alias KanbanWeb.API.TaskController
  alias KanbanWeb.API.TaskErrors
  alias KanbanWeb.API.TaskParamFilter

  @doc """
  Creates each goal in `goals` in order, stopping on the first failure. Returns
  `{:ok, results}` (newest-first; `handle_batch_result/2` reverses) or
  `{:error, index, changeset | reason}`.
  """
  def process_batch_goals(goals, column, user, api_token, conn) do
    ctx = %{column: column, user: user, api_token: api_token, conn: conn}

    goals
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {goal_params, index}, {:ok, acc} ->
      create_single_goal_in_batch(goal_params, index, ctx, acc)
    end)
  end

  defp create_single_goal_in_batch(goal_params, index, ctx, acc) do
    {safe_goal_params, rejected_goal_fields} =
      TaskParamFilter.filter_forbidden_create_fields(goal_params)

    child_tasks_raw = Map.get(goal_params, "tasks", [])

    {safe_child_tasks, rejected_child_fields} =
      TaskParamFilter.filter_child_tasks(child_tasks_raw)

    TaskController.log_create_forbidden_fields(
      ctx.conn,
      rejected_goal_fields,
      rejected_child_fields
    )

    task_params_with_creator =
      TaskController.build_task_params_with_creator(safe_goal_params, ctx.user, ctx.api_token)

    case Tasks.api_create_goal_with_tasks(ctx.column, task_params_with_creator, safe_child_tasks) do
      {:ok, %{goal: goal, child_tasks: created_child_tasks}} ->
        handle_successful_goal_creation(goal, created_child_tasks, index, ctx.conn, acc)

      {:error, _operation, changeset} ->
        {:halt, {:error, index, changeset}}
    end
  end

  defp handle_successful_goal_creation(goal, created_child_tasks, index, conn, acc) do
    goal = Tasks.get_task_for_view!(goal.id)

    TaskController.emit_telemetry(conn, :goal_created, %{
      goal_id: goal.id,
      child_task_count: length(created_child_tasks),
      batch: true,
      batch_index: index
    })

    result = %{
      goal: TaskController.render_goal_with_children(goal),
      child_tasks: Enum.map(created_child_tasks, &TaskController.render_task_summary/1)
    }

    {:cont, {:ok, [result | acc]}}
  end

  @doc """
  Renders the terminal batch response from the aggregation result: 201 on
  success, 422 with per-index details on a changeset failure, or 422 on a
  WIP-limit failure.
  """
  def handle_batch_result({:ok, created_goals}, conn) do
    TaskController.emit_telemetry(conn, :batch_goals_created, %{
      total_goals: length(created_goals)
    })

    conn
    |> put_status(:created)
    |> json(%{
      success: true,
      goals: Enum.reverse(created_goals),
      total: length(created_goals)
    })
  end

  def handle_batch_result({:error, index, changeset}, conn)
      when is_struct(changeset, Ecto.Changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "Failed to create goal at index #{index}",
      index: index,
      details: TaskErrors.translate_changeset_errors(changeset)
    })
  end

  def handle_batch_result({:error, index, :wip_limit_reached}, conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "WIP limit reached while creating goal at index #{index}",
      index: index
    })
  end
end
