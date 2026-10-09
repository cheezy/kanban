defmodule KanbanWeb.API.TaskCreation do
  @moduledoc """
  Single-task and goal creation for `POST /api/tasks`, split from
  `KanbanWeb.API.TaskController` to keep the controller under the module size
  guideline.

  `create/3` runs after the controller's live board-write check (D109) has
  passed: it resolves the target column board-scoped (W399), filters
  mass-assigned fields (`KanbanWeb.API.TaskParamFilter`), stamps the creator,
  and creates either a plain task or a goal with nested child tasks, rendering
  the 201 (with a `location` header) or the 422.

  The creation helpers `build_task_params_with_creator/4`,
  `log_create_forbidden_fields/3`, `render_goal_with_children/1` and
  `get_default_column_id/1` are public because `KanbanWeb.API.BatchGoalCreation`
  composes them for `POST /api/tasks/batch`. Like `KanbanWeb.API.TaskErrors`,
  this module takes `conn` and renders; the statuses, bodies and telemetry
  events are exactly the ones the controller produced inline.
  """

  use KanbanWeb, :verified_routes

  import Plug.Conn, only: [put_status: 2, put_resp_header: 3]
  import Phoenix.Controller, only: [json: 2, render: 3]

  alias Kanban.ApiTokens
  alias Kanban.Columns
  alias Kanban.Tasks
  alias KanbanWeb.API.AgentAttribution
  alias KanbanWeb.API.TaskActions
  alias KanbanWeb.API.TaskErrors
  alias KanbanWeb.API.TaskJSON
  alias KanbanWeb.API.TaskLabels
  alias KanbanWeb.API.TaskParamFilter

  @doc """
  Creates the task (or goal with child tasks) described by `task_params` on the
  conn's board, attributed to the conn's user, API token and `agent_name`.
  The caller must already have authorized the board write.
  """
  def create(conn, task_params, agent_name) do
    board = conn.assigns.current_board

    creator = %{
      user: conn.assigns.current_user,
      api_token: conn.assigns.api_token,
      agent_name: agent_name
    }

    # D137: best-effort, post-authorization; a failed stamp never fails create.
    ApiTokens.stamp_last_agent_name(creator.api_token, agent_name)

    case TaskActions.parse_id(task_params["column_id"] || get_default_column_id(board)) do
      {:ok, column_id} ->
        resolve_column_and_create(conn, board, column_id, task_params, creator)

      :error ->
        TaskErrors.error_response(
          conn,
          :bad_request,
          "Invalid column_id: must be an integer",
          :invalid_param
        )
    end
  end

  defp resolve_column_and_create(conn, board, column_id, task_params, creator) do
    # Board-scoped lookup unifies "no such column" and "column on other
    # board" into a single not_found response (W399).
    case TaskActions.column_for_board(column_id, board.id) do
      nil ->
        TaskErrors.handle_task_error(conn, {:error, :not_found})

      column ->
        perform_api_task_create(conn, column, task_params, creator)
    end
  end

  defp perform_api_task_create(conn, column, task_params, creator) do
    {safe_task_params, rejected_goal_fields} =
      TaskParamFilter.filter_forbidden_create_fields(task_params)

    child_tasks_raw = Map.get(task_params, "tasks", [])

    {safe_child_tasks, rejected_child_fields} =
      TaskParamFilter.filter_child_tasks(child_tasks_raw)

    log_create_forbidden_fields(conn, rejected_goal_fields, rejected_child_fields)

    # W2239: labels are resolved and validated before any row is written, so
    # an unknown name is a 422 that leaves nothing behind.
    conn
    |> TaskLabels.scope()
    |> TaskLabels.prepare_create(conn.assigns.current_board, safe_task_params, safe_child_tasks)
    |> create_with_labels(conn, column, creator)
  end

  defp create_with_labels({:ok, task_params, child_tasks, label_plan}, conn, column, creator) do
    task_params_with_creator =
      build_task_params_with_creator(
        task_params,
        creator.user,
        creator.api_token,
        creator.agent_name
      )

    insert_task_or_goal(conn, column, task_params_with_creator, child_tasks, label_plan)
  end

  defp create_with_labels({:error, changeset}, conn, _column, _creator),
    do: handle_task_creation({:error, changeset}, conn, nil)

  defp insert_task_or_goal(conn, column, task_params, child_tasks, label_plan) do
    if child_tasks != [] do
      column
      |> Tasks.api_create_goal_with_tasks(task_params, child_tasks)
      |> handle_goal_creation(conn, label_plan)
    else
      column
      |> Tasks.api_create_task(task_params)
      |> handle_task_creation(conn, label_plan)
    end
  end

  @doc false
  def build_task_params_with_creator(task_params, user, api_token, agent_name) do
    task_params
    |> Map.put("created_by_id", user.id)
    |> maybe_add_created_by_agent(api_token, agent_name)
    |> Map.delete("column_id")
  end

  defp handle_task_creation({:ok, task}, conn, label_plan) do
    conn |> TaskLabels.scope() |> TaskLabels.apply_plan(task, label_plan.task)
    task = Tasks.get_task_for_view!(task.id)
    TaskActions.emit_telemetry(conn, :task_created, %{task_id: task.id})

    conn
    |> put_status(:created)
    |> put_resp_header("location", ~p"/api/tasks/#{task}")
    |> render(:show, task: task)
  end

  defp handle_task_creation({:error, %Ecto.Changeset{} = changeset}, conn, _label_plan) do
    conn
    |> put_status(:unprocessable_entity)
    |> render(:error, changeset: changeset)
  end

  # D356: a work or defect task created in a column at its WIP limit. Without
  # this clause the reason fell through to FunctionClauseError and a 500.
  defp handle_task_creation({:error, :wip_limit_reached} = error, conn, _label_plan) do
    TaskErrors.handle_task_error(conn, error)
  end

  defp handle_goal_creation({:ok, %{goal: goal, child_tasks: child_tasks}}, conn, label_plan) do
    scope = TaskLabels.scope(conn)
    TaskLabels.apply_plan(scope, goal, label_plan.task)
    TaskLabels.apply_children(scope, child_tasks, label_plan.children)
    goal = Tasks.get_task_for_view!(goal.id)

    TaskActions.emit_telemetry(conn, :goal_created, %{
      goal_id: goal.id,
      child_task_count: length(child_tasks)
    })

    conn
    |> put_status(:created)
    |> put_resp_header("location", ~p"/api/tasks/#{goal}")
    |> json(%{
      goal: render_goal_with_children(goal),
      child_tasks: Enum.map(child_tasks, &TaskJSON.render_task_summary/1)
    })
  end

  defp handle_goal_creation(
         {:error, _operation, %Ecto.Changeset{} = changeset},
         conn,
         _label_plan
       ) do
    conn
    |> put_status(:unprocessable_entity)
    |> render(:error, changeset: changeset)
  end

  @doc false
  def render_goal_with_children(goal) do
    %{
      id: goal.id,
      identifier: goal.identifier,
      title: goal.title,
      description: goal.description,
      status: goal.status,
      priority: goal.priority,
      complexity: goal.complexity,
      type: goal.type,
      created_by_id: goal.created_by_id,
      created_by_agent: goal.created_by_agent,
      column_id: goal.column_id,
      inserted_at: goal.inserted_at,
      updated_at: goal.updated_at
    }
  end

  @doc false
  def get_default_column_id(board) do
    columns = Columns.list_columns(board)

    backlog = Enum.find(columns, fn col -> col.name == "Backlog" end)
    ready = Enum.find(columns, fn col -> col.name == "Ready" end)

    cond do
      backlog -> backlog.id
      ready -> ready.id
      true -> List.first(columns).id
    end
  end

  # D137: an explicit created_by_agent field wins; otherwise the shared
  # KanbanWeb.API.AgentAttribution order applies (token agent_model, then the
  # agent_name param, then the token's last_agent_name, else unset, which the
  # agents feed renders as "?").
  defp maybe_add_created_by_agent(task_params, api_token, agent_name) do
    if Map.has_key?(task_params, "created_by_agent") do
      task_params
    else
      case AgentAttribution.resolve(api_token, agent_name) do
        nil -> task_params
        agent -> Map.put(task_params, "created_by_agent", agent)
      end
    end
  end

  # Emits the create-path mass-assignment audit log (via TaskParamFilter) and,
  # when a forbidden field was rejected, the companion telemetry event. The
  # audit Logger line lives in TaskParamFilter; telemetry stays here because
  # emit_telemetry/3 is controller-wide infra keyed off conn.
  @doc false
  def log_create_forbidden_fields(conn, goal_fields, child_fields) do
    TaskParamFilter.log_create_mass_assignment(
      goal_fields,
      child_fields,
      TaskParamFilter.actor_user_id(conn)
    )

    if goal_fields != [] or child_fields != [] do
      TaskActions.emit_telemetry(conn, :task_create_forbidden_fields_filtered, %{
        goal_fields: goal_fields,
        child_fields: child_fields
      })
    end
  end
end
