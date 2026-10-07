defmodule KanbanWeb.API.TaskController do
  use KanbanWeb, :controller

  alias Kanban.Boards
  alias Kanban.Columns
  alias Kanban.Tasks
  alias KanbanWeb.API.BatchGoalCreation
  alias KanbanWeb.API.ChangedFilesTransport
  alias KanbanWeb.API.TaskActions
  alias KanbanWeb.API.TaskCreation
  alias KanbanWeb.API.TaskErrors
  alias KanbanWeb.API.TaskFieldsProjection
  alias KanbanWeb.API.TaskJSON
  alias KanbanWeb.API.TaskListParams
  alias KanbanWeb.API.TaskRequestRejections
  alias KanbanWeb.API.TaskTransitions
  alias KanbanWeb.API.TaskUpdate

  require Logger

  action_fallback KanbanWeb.API.FallbackController

  # W2057: the view is resolved from the request once, here, and applied at
  # render only — the board scoping and the query underneath are identical in
  # both views, so the slim view can only narrow a row, never widen it or
  # surface a task the full view withheld.
  def index(conn, params) do
    board = conn.assigns.current_board
    view = view_for(params)

    # W2224: pagination and filters are opt-in by key presence. With none of
    # the page keys present the two legacy branches below run exactly as
    # before, so the unpaginated response stays byte-identical.
    cond do
      TaskListParams.paginated?(params) ->
        list_board_tasks_page(conn, params)

      params["column_id"] ->
        list_tasks_by_column_id(conn, board, params["column_id"], view)

      true ->
        list_all_board_tasks(conn, board, view)
    end
  end

  defp list_tasks_by_column_id(conn, board, raw_column_id, view) do
    case parse_id(raw_column_id) do
      {:ok, column_id} ->
        # Board-scoped lookup so a cross-board column id and a nonexistent
        # column id produce the same {:error, :not_found} response — closes
        # the existence-oracle gap that the old get_column! + verify pattern
        # had (W399).
        case column_for_board(column_id, board.id) do
          nil ->
            TaskErrors.handle_task_error(conn, {:error, :not_found})

          column ->
            tasks = Tasks.list_tasks(column)
            emit_telemetry(conn, :task_listed, %{count: length(tasks)})
            render(conn, :index, tasks: tasks, response_view: view)
        end

      :error ->
        TaskErrors.error_response(
          conn,
          :bad_request,
          "Invalid column_id: must be an integer",
          :invalid_param
        )
    end
  end

  defp list_all_board_tasks(conn, board, view) do
    columns = Columns.list_columns(board)
    tasks = Enum.flat_map(columns, &Tasks.list_tasks/1)
    emit_telemetry(conn, :task_listed, %{count: length(tasks)})
    render(conn, :index, tasks: tasks, response_view: view)
  end

  # W2224: the paginated mode lives in TaskActions.list_page/2, shared with the
  # MCP stride_list_tasks tool (W2231).
  defp list_board_tasks_page(conn, params) do
    respond(conn, TaskActions.list_page(conn, params))
  end

  # W2076: fields resolution runs before the task is fetched — validation is
  # pure, so the reject path never touches task data and cannot become an
  # existence oracle. The success path keeps the identical board-scoped
  # fetch_and_verify_task/2 the unprojected show has always used.
  def show(conn, %{"id" => id_or_identifier} = params) do
    board = conn.assigns.current_board

    case TaskFieldsProjection.resolve(params) do
      {:ok, fields} ->
        show_task(conn, id_or_identifier, board, params, fields)

      {:error, :mutually_exclusive} ->
        TaskRequestRejections.reject_fields_response_view_conflict(conn)

      {:error, :invalid_shape} ->
        TaskRequestRejections.reject_invalid_fields_shape(conn)

      {:error, {:unknown_fields, unknown}} ->
        TaskRequestRejections.reject_unknown_fields(conn, unknown)
    end
  end

  # nil fields = no projection requested: the legacy render, byte-identical
  # to the pre-W2076 path, shared with the MCP stride_get_task tool (W2231).
  # A validated fields list renders the projection and deliberately threads
  # no response_view assign — the two are mutually exclusive at resolve/1.
  defp show_task(conn, id_or_identifier, _board, params, nil) do
    respond(conn, TaskActions.get_task(conn, id_or_identifier, params))
  end

  defp show_task(conn, id_or_identifier, board, _params, fields) do
    case fetch_and_verify_task(id_or_identifier, board) do
      {:ok, task} -> render(conn, :show, task: task, fields: fields)
      error -> TaskErrors.handle_task_error(conn, error)
    end
  end

  def create(conn, %{"data" => _data}),
    do: TaskRequestRejections.reject_malformed_request(conn, :create_invalid_root_key)

  def create(conn, %{"task" => task_params} = params) do
    case authorize_board_write(conn) do
      :ok -> TaskCreation.create(conn, task_params, params["agent_name"])
      error -> TaskErrors.handle_task_error(conn, error)
    end
  end

  def create(conn, _params),
    do: TaskRequestRejections.reject_malformed_request(conn, :create_missing_task_key)

  # D109: live board-write re-check for the API create/update paths (W1430
  # in-depth), matching claim/complete/unclaim. Cross-board scope and
  # mass-assignment filtering already apply; this rejects a token whose user lost
  # :owner/:modify access but that escaped revocation.
  defp authorize_board_write(conn) do
    TaskActions.authorize_board_write(conn.assigns.current_board, conn.assigns.current_user)
  end

  def batch_create(conn, %{"tasks" => _tasks}),
    do: TaskRequestRejections.reject_malformed_request(conn, :batch_create_invalid_root_key)

  def batch_create(conn, %{"goals" => goals} = params) do
    case authorize_board_write(conn) do
      :ok -> BatchGoalCreation.create_batch(conn, goals, params)
      error -> TaskErrors.handle_task_error(conn, error)
    end
  end

  def batch_create(conn, _params),
    do: TaskRequestRejections.reject_malformed_request(conn, :batch_create_missing_goals_key)

  def update(conn, %{"id" => _id_or_identifier, "data" => _data}),
    do: TaskRequestRejections.reject_malformed_request(conn, :update_invalid_root_key)

  def update(conn, %{"id" => id_or_identifier, "task" => task_params}) do
    case authorize_board_write(conn) do
      :ok -> TaskUpdate.update(conn, id_or_identifier, task_params)
      error -> TaskErrors.handle_task_error(conn, error)
    end
  end

  def update(conn, %{"id" => _id_or_identifier}),
    do: TaskRequestRejections.reject_malformed_request(conn, :update_missing_task_key)

  # W2231: next, claim and complete delegate to TaskActions, which the MCP
  # tools call too, so both transports share one validation path.
  def next(conn, params), do: respond(conn, TaskActions.next_task(conn, params))

  def claim(conn, params), do: respond(conn, TaskActions.claim(conn, params))

  # Logs the underlying reason server-side and returns a stable user-facing
  # body so the response does not leak implementation detail to API clients.
  # Exposed for testing.
  @doc false
  def handle_unexpected_claim_error(conn, reason, metadata) do
    TaskActions.log_unexpected_claim_error(reason, metadata)
    TaskErrors.render_error(conn, :claim_failed)
  end

  @doc false
  defdelegate unexpected_claim_error_body, to: TaskErrors

  def complete(conn, %{"id" => id_or_identifier} = params) do
    respond(conn, TaskActions.complete(conn, id_or_identifier, params))
  end

  @doc false
  defdelegate view_for(params), to: TaskActions

  defp respond(conn, {:ok, template, assigns}), do: render(conn, template, assigns)
  defp respond(conn, {:error, reason}), do: TaskErrors.render_error(conn, reason)

  def put_changed_files(conn, %{"id" => id_or_identifier} = params) do
    # Accept the wrapped {changed_files: [...]} shape (canonical), a top-level
    # JSON array body (which Plug.Parsers routes to _json, accommodating older
    # or misshaped plugin payloads), and the transport-encoded envelope
    # {changed_files: {encoding: "base64"|"gzip+base64", data: "..."}} (D61).
    # The encoded form lets a unified code diff upload even when an edge filter
    # would otherwise misread the raw text as an attack; it is decoded back to
    # the same list the raw shapes carry (see
    # ChangedFilesTransport.decode_and_validate_changed_files/1).
    payload = params["changed_files"] || params["_json"]

    case persist_changed_files(conn, id_or_identifier, payload) do
      {:ok, task, value} -> render_changed_files_response(conn, task, value, view_for(params))
      error -> TaskErrors.handle_task_error(conn, error)
    end
  end

  defp persist_changed_files(conn, id_or_identifier, payload) do
    board = conn.assigns.current_board
    user = conn.assigns.current_user

    with {:ok, task} <- fetch_and_verify_task(id_or_identifier, board),
         :ok <- authorize_changed_files(task, user),
         {:ok, value} <- ChangedFilesTransport.decode_and_validate_changed_files(payload),
         {:ok, updated} <- Tasks.update_changed_files(task, value) do
      {:ok, updated, value}
    end
  end

  # W2056: the view is resolved from the request but applied HERE, on the
  # success path only — `persist_changed_files/2` has already authorized the
  # write, so an unauthorized caller is rejected before any view exists to
  # choose. Slim never widens what a caller can read: it strictly removes the
  # echoed `changed_files` from a response that caller was already entitled to.
  defp render_changed_files_response(conn, task, value, view) do
    # `task` is already preloaded (column, assigned_to, …) because
    # `fetch_and_verify_task/2` loads via `get_task_for_view`; the no-op
    # `Ecto.Changeset.change/2` preserves those associations. No refetch.
    emit_telemetry(conn, :task_changed_files_persisted, %{
      task_id: task.id,
      file_count: length(value || [])
    })

    case view do
      :slim -> render(conn, :ack, task: task)
      :full -> render(conn, :show, task: task)
    end
  end

  # changed_files write access: the task's assignee, OR an authorized reviewer
  # (a board member with :owner/:modify access). The old clause allowed ANY
  # board-scoped token holder to overwrite the diff snapshot of any task in a
  # column literally named "Review" — a non-assignee/non-reviewer could tamper
  # with the artifact human reviewers inspect (W1433). Authorship is preserved
  # across completion (assigned_to_id is not cleared), so the assignee clause
  # still covers a completed task sitting in Review.
  defp authorize_changed_files(%{assigned_to_id: user_id}, %{id: user_id}), do: :ok

  defp authorize_changed_files(%{column: %{board_id: board_id}}, %{id: user_id}) do
    if Boards.get_user_access(board_id, user_id) in [:owner, :modify] do
      :ok
    else
      {:error, :not_authorized_changed_files}
    end
  end

  defp authorize_changed_files(_task, _user), do: {:error, :not_authorized_changed_files}

  def unclaim(conn, %{"id" => id_or_identifier} = params) do
    board = conn.assigns.current_board
    user = conn.assigns.current_user

    case fetch_and_verify_task(id_or_identifier, board) do
      {:ok, task} ->
        reason = TaskTransitions.unclaim_reason(params)
        TaskTransitions.proceed_with_unclaim(conn, task, user, reason)

      error ->
        TaskErrors.handle_task_error(conn, error)
    end
  end

  def mark_reviewed(conn, %{"id" => id_or_identifier} = params) do
    board = conn.assigns.current_board
    user = conn.assigns.current_user

    with {:ok, task} <- fetch_and_verify_task(id_or_identifier, board),
         :ok <- validate_hook(params["after_review_result"], "after_review") do
      TaskTransitions.proceed_with_mark_reviewed(conn, task, user)
    else
      error -> TaskErrors.handle_task_error(conn, error)
    end
  end

  def mark_done(conn, %{"id" => id_or_identifier}) do
    board = conn.assigns.current_board
    user = conn.assigns.current_user

    case fetch_and_verify_task(id_or_identifier, board) do
      {:ok, task} -> TaskTransitions.proceed_with_mark_done(conn, task, user)
      error -> TaskErrors.handle_task_error(conn, error)
    end
  end

  @doc """
  Agent-result endpoint for the after_goal hook (W493 / G113).

  PATCH /api/tasks/:id/after_goal accepts `{exit_code, output, duration_ms}`
  and writes the result onto the goal:

    * `exit_code == 0` → flips `after_goal_status` to `:succeeded`,
      records the attempt, and promotes the goal to Done.
    * `exit_code != 0` → appends to the audit log; goal stays In
      Progress and remains re-runnable. The latest report wins for
      `after_goal_result`; the full attempt log is preserved in
      `after_goal_attempts`.

  Idempotent — calling against a goal already in `:succeeded` records
  the attempt (auditable) without re-promoting; calling against a goal
  that never had an after_goal lifecycle returns 422.

  Only valid on tasks of type `:goal` whose `after_goal_status` is
  `:pending` or `:succeeded`.
  """
  def after_goal(conn, %{"id" => id_or_identifier} = params) do
    board = conn.assigns.current_board

    with {:ok, task} <-
           TaskTransitions.fetch_verify_and_authorize_after_goal(
             id_or_identifier,
             board,
             conn.assigns.current_user
           ),
         :ok <- TaskTransitions.validate_after_goal_target(task),
         {:ok, attempt} <- TaskTransitions.validate_after_goal_result(params) do
      TaskTransitions.proceed_with_after_goal(conn, task, attempt)
    else
      error -> TaskErrors.handle_task_error(conn, error)
    end
  end

  def dependencies(conn, %{"id" => id_or_identifier}) do
    board = conn.assigns.current_board

    case fetch_and_verify_task(id_or_identifier, board) do
      {:ok, task} ->
        dependency_tree = Tasks.get_dependency_tree(task)
        emit_telemetry(conn, :dependencies_fetched, %{task_id: task.id})

        json(conn, %{
          task: TaskJSON.render_task_summary(task),
          dependencies: render_dependency_tree(dependency_tree.dependencies)
        })

      error ->
        TaskErrors.handle_task_error(conn, error)
    end
  end

  def dependents(conn, %{"id" => id_or_identifier}) do
    board = conn.assigns.current_board

    case fetch_and_verify_task(id_or_identifier, board) do
      {:ok, task} ->
        dependent_tasks = Tasks.get_dependent_tasks(task)

        emit_telemetry(conn, :dependents_fetched, %{
          task_id: task.id,
          count: length(dependent_tasks)
        })

        json(conn, %{
          task: TaskJSON.render_task_summary(task),
          dependents: Enum.map(dependent_tasks, &TaskJSON.render_task_summary/1)
        })

      error ->
        TaskErrors.handle_task_error(conn, error)
    end
  end

  def tree(conn, %{"id" => id_or_identifier} = params) do
    board = conn.assigns.current_board

    case fetch_and_verify_task(id_or_identifier, board) do
      {:ok, task} ->
        tree_data = Tasks.get_task_tree(task.id, board.id)
        emit_telemetry(conn, :task_tree_fetched, %{task_id: task.id})
        render(conn, :tree, tree: tree_data, response_view: view_for(params))

      error ->
        TaskErrors.handle_task_error(conn, error)
    end
  end

  @doc """
  Returns a compact, read-only after_goal status for task `:id`.

  The Stride hook calls this itself — independent of the large, truncatable
  `/complete` response — to learn whether completing `:id` armed an `after_goal`
  and to fetch the `GOAL_*` env needed to run the local `## after_goal` section.
  Board-scoped and Bearer-authed exactly like `:tree` and `:after_goal`; makes
  no state change (the `/after_goal` PATCH and the grace worker own transitions).
  """
  def after_goal_status(conn, %{"id" => id_or_identifier}) do
    board = conn.assigns.current_board

    case fetch_and_verify_task(id_or_identifier, board) do
      {:ok, task} ->
        goal = Tasks.after_goal_armed_goal(task, board.id)
        emit_telemetry(conn, :after_goal_status_fetched, %{task_id: task.id})
        render(conn, :after_goal_status, goal: goal, board: board)

      error ->
        TaskErrors.handle_task_error(conn, error)
    end
  end

  defp fetch_and_verify_task(id_or_identifier, board),
    do: TaskActions.fetch_task(id_or_identifier, board)

  defp validate_hook(result, hook_name), do: TaskActions.validate_hook(result, hook_name)

  # Exposed (with render_task_summary/1) so KanbanWeb.API.BatchGoalCreation can
  # call it by name; the event itself is owned by KanbanWeb.API.TaskActions.
  @doc false
  defdelegate emit_telemetry(conn, event_name, metadata), to: TaskActions

  # The goal shape is owned by KanbanWeb.API.TaskCreation; this delegate keeps
  # TaskController.render_goal_with_children/1 resolving for existing callers.
  @doc false
  defdelegate render_goal_with_children(goal), to: TaskCreation

  # The summary shape itself lives in KanbanWeb.API.TaskJSON, which owns it.
  # This delegate exists solely so KanbanWeb.API.BatchGoalCreation, which calls
  # TaskController.render_task_summary/1 by name, keeps resolving unchanged.
  @doc false
  defdelegate render_task_summary(task), to: TaskJSON

  defp render_dependency_tree(dependencies) do
    Enum.map(dependencies, fn dep_tree ->
      %{
        task: TaskJSON.render_task_summary(dep_tree.task),
        dependencies: render_dependency_tree(dep_tree.dependencies)
      }
    end)
  end

  defp column_for_board(column_id, board_id),
    do: TaskActions.column_for_board(column_id, board_id)

  defp parse_id(id), do: TaskActions.parse_id(id)
end
