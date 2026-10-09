defmodule KanbanWeb.API.BatchGoalCreation do
  @moduledoc """
  Batch goal creation for `POST /api/tasks/batch`, extracted from
  `KanbanWeb.API.TaskController` (W1444).

  Processes a list of goal params one at a time, stopping on the first failure
  (`Enum.reduce_while`), and renders the documented batch response — the 201
  success shape and the 422 changeset shape (`error`/`index`/`details`). The
  exact success/failure aggregation and those response bodies are documented
  in `docs/api/post_tasks_batch.md` and matched by the request-test suite, so
  they must not drift. The 422 WIP-limit clause is kept only so its body stays
  stable: goal creation never runs the WIP check, so it cannot currently be
  reached, and the batch docs no longer describe it (D356).

  `create_batch/3` (moved here from the controller's `batch_create/2` body
  when the controller was split to stay under the module size guideline) runs
  after the live board-write check and resolves the board's default column.
  It then validates the `labels` of every goal and child task for the whole
  batch through `KanbanWeb.API.TaskLabels.prepare_batch/3` before creating
  anything, so an unknown label name returns the 422 changeset shape for the
  offending goal's index and no goal is created (W2239).

  Like `KanbanWeb.API.TaskErrors`, this module takes `conn` and renders. It
  reuses the shared creation helpers (`build_task_params_with_creator/4`,
  `log_create_forbidden_fields/3`, `render_goal_with_children/1`,
  `get_default_column_id/1`) from `KanbanWeb.API.TaskCreation`, which owns them
  because the single-create action shares them, plus the controller's
  `emit_telemetry/3` and `render_task_summary/1` delegates — the summary shape
  is owned by `KanbanWeb.API.TaskJSON`; the controller keeps a delegate under
  that name so the call below resolves unchanged.
  """

  import Plug.Conn, only: [put_status: 2]
  import Phoenix.Controller, only: [json: 2]

  alias Kanban.Columns
  alias Kanban.Tasks
  alias KanbanWeb.API.TaskActions
  alias KanbanWeb.API.TaskController
  alias KanbanWeb.API.TaskCreation
  alias KanbanWeb.API.TaskErrors
  alias KanbanWeb.API.TaskLabels
  alias KanbanWeb.API.TaskParamFilter

  @doc """
  Creates every goal in `goals` in the board's default column and renders the
  batch response. The caller must already have authorized the board write.
  """
  # Mirrors the live board-write re-check that create/2, update/2, and
  # after_goal enforce (D108/D109): a token whose user has only view/read-only
  # access — or whose owner/modify access was downgraded after the token was
  # issued — must not bulk-create goals via this endpoint. Called only after
  # authorize_board_write/1 passes, so no side effect runs for an unauthorized
  # caller.
  def create_batch(conn, goals, params) do
    board = conn.assigns.current_board
    user = conn.assigns.current_user
    api_token = conn.assigns.api_token
    agent_name = params["agent_name"]

    TaskActions.stamp_agent_identity(conn, params)

    column_id = TaskCreation.get_default_column_id(board)

    # Board-scoped lookup; default column should always exist on the board, so
    # this is defense-in-depth in case get_default_column_id returns nil/stale.
    case column_id && Columns.get_column_for_board(column_id, board.id) do
      nil ->
        TaskErrors.handle_task_error(conn, {:error, :not_found})

      column ->
        conn
        |> prepare_goal_labels(board, goals)
        |> create_prepared_goals(column, user, api_token, agent_name, conn)
    end
  end

  # W2239: every goal's and child's labels are checked before the first goal
  # is created, because goals are created one transaction at a time and an
  # earlier goal would otherwise survive a later label error. A non-list
  # `goals` (:skip) keeps its pre-W2239 handling, with no labels applied.
  defp prepare_goal_labels(conn, board, goals) do
    case conn |> TaskLabels.scope() |> TaskLabels.prepare_batch(board, goals) do
      :skip -> {:ok, Enum.map(goals, &{&1, nil})}
      result -> result
    end
  end

  defp create_prepared_goals({:ok, prepared}, column, user, api_token, agent_name, conn) do
    prepared
    |> process_batch_goals(column, user, api_token, agent_name, conn)
    |> handle_batch_result(conn)
  end

  defp create_prepared_goals({:error, index, changeset}, _column, _user, _token, _agent, conn),
    do: handle_batch_result({:error, index, changeset}, conn)

  @doc """
  Creates each goal in `goals` in order, stopping on the first failure. Returns
  `{:ok, results}` (newest-first; `handle_batch_result/2` reverses) or
  `{:error, index, changeset | reason}`.

  Each entry of `goals` is `{goal_params, label_plan}`: the goal's params with
  `labels` already stripped, and its resolved labels from
  `KanbanWeb.API.TaskLabels.prepare_batch/3` (`nil` applies none) (W2239).
  """
  def process_batch_goals(goals, column, user, api_token, agent_name, conn) do
    ctx = %{column: column, user: user, api_token: api_token, agent_name: agent_name, conn: conn}

    goals
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{goal_params, plan}, index}, {:ok, acc} ->
      create_single_goal_in_batch(goal_params, index, Map.put(ctx, :label_plan, plan), acc)
    end)
  end

  defp create_single_goal_in_batch(goal_params, index, ctx, acc) do
    {safe_goal_params, rejected_goal_fields} =
      TaskParamFilter.filter_forbidden_create_fields(goal_params)

    child_tasks_raw = Map.get(goal_params, "tasks", [])

    {safe_child_tasks, rejected_child_fields} =
      TaskParamFilter.filter_child_tasks(child_tasks_raw)

    TaskCreation.log_create_forbidden_fields(
      ctx.conn,
      rejected_goal_fields,
      rejected_child_fields
    )

    task_params_with_creator =
      TaskCreation.build_task_params_with_creator(
        safe_goal_params,
        ctx.user,
        ctx.api_token,
        ctx.agent_name
      )

    case Tasks.api_create_goal_with_tasks(ctx.column, task_params_with_creator, safe_child_tasks) do
      {:ok, %{goal: goal, child_tasks: created_child_tasks}} ->
        handle_successful_goal_creation(goal, created_child_tasks, index, ctx, acc)

      {:error, _operation, changeset} ->
        {:halt, {:error, index, changeset}}
    end
  end

  defp apply_label_plan(%{label_plan: nil}, _goal, _children), do: :ok

  defp apply_label_plan(%{label_plan: plan, conn: conn}, goal, children) do
    scope = TaskLabels.scope(conn)
    TaskLabels.apply_plan(scope, goal, plan.task)
    TaskLabels.apply_children(scope, children, plan.children)
  end

  defp handle_successful_goal_creation(goal, created_child_tasks, index, ctx, acc) do
    %{conn: conn} = ctx
    apply_label_plan(ctx, goal, created_child_tasks)
    goal = Tasks.get_task_for_view!(goal.id)

    TaskController.emit_telemetry(conn, :goal_created, %{
      goal_id: goal.id,
      child_task_count: length(created_child_tasks),
      batch: true,
      batch_index: index
    })

    result = %{
      goal: TaskCreation.render_goal_with_children(goal),
      child_tasks: Enum.map(created_child_tasks, &TaskController.render_task_summary/1)
    }

    {:cont, {:ok, [result | acc]}}
  end

  @doc """
  Renders the terminal batch response from the aggregation result: 201 on
  success, 422 with per-index details on a changeset failure, or 422 on a
  WIP-limit failure. The WIP-limit clause is currently unreachable, because
  goal creation never checks WIP limits; it is retained for body stability.
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
