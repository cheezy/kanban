defmodule KanbanWeb.API.TaskController do
  use KanbanWeb, :controller

  alias Kanban.ApiTokens
  alias Kanban.Boards
  alias Kanban.Columns
  alias Kanban.Tasks
  alias KanbanWeb.API.BatchGoalCreation
  alias KanbanWeb.API.ChangedFilesTransport
  alias KanbanWeb.API.CompletionResultGate
  alias KanbanWeb.API.ErrorDocs
  alias KanbanWeb.API.TaskErrors
  alias KanbanWeb.API.TaskParamFilter

  require Logger

  action_fallback KanbanWeb.API.FallbackController

  def index(conn, params) do
    board = conn.assigns.current_board

    if params["column_id"] do
      list_tasks_by_column_id(conn, board, params["column_id"])
    else
      list_all_board_tasks(conn, board)
    end
  end

  defp list_tasks_by_column_id(conn, board, raw_column_id) do
    case parse_id(raw_column_id) do
      {:ok, column_id} ->
        # Board-scoped lookup so a cross-board column id and a nonexistent
        # column id produce the same {:error, :not_found} response — closes
        # the existence-oracle gap that the old get_column! + verify pattern
        # had (W399).
        case Columns.get_column_for_board(column_id, board.id) do
          nil ->
            TaskErrors.handle_task_error(conn, {:error, :not_found})

          column ->
            tasks = Tasks.list_tasks(column)
            emit_telemetry(conn, :task_listed, %{count: length(tasks)})
            render(conn, :index, tasks: tasks)
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

  defp list_all_board_tasks(conn, board) do
    columns = Columns.list_columns(board)
    tasks = Enum.flat_map(columns, &Tasks.list_tasks/1)
    emit_telemetry(conn, :task_listed, %{count: length(tasks)})
    render(conn, :index, tasks: tasks)
  end

  def show(conn, %{"id" => id_or_identifier}) do
    board = conn.assigns.current_board

    case fetch_and_verify_task(id_or_identifier, board) do
      {:ok, task} -> render(conn, :show, task: task)
      error -> TaskErrors.handle_task_error(conn, error)
    end
  end

  def create(conn, %{"data" => _data}) do
    error_response =
      ErrorDocs.add_docs_to_error(
        %{
          error:
            "Invalid request format. The request body key must be 'task', not 'data'. See documentation for correct format.",
          example: %{
            task: %{
              title: "Task title",
              description: "Task description",
              type: "work",
              priority: "medium"
            }
          }
        },
        :create_invalid_root_key
      )

    conn
    |> put_status(:unprocessable_entity)
    |> json(error_response)
  end

  def create(conn, %{"task" => task_params} = params) do
    case authorize_board_write(conn) do
      :ok -> do_create(conn, task_params, params["agent_name"])
      error -> TaskErrors.handle_task_error(conn, error)
    end
  end

  def create(conn, _params) do
    error_response =
      ErrorDocs.add_docs_to_error(
        %{
          error:
            "Invalid request format. Missing 'task' key in request body. See documentation for correct format.",
          example: %{
            task: %{
              title: "Task title",
              description: "Task description",
              type: "work",
              priority: "medium"
            }
          }
        },
        :create_missing_task_key
      )

    conn
    |> put_status(:unprocessable_entity)
    |> json(error_response)
  end

  defp do_create(conn, task_params, agent_name) do
    board = conn.assigns.current_board

    creator = %{
      user: conn.assigns.current_user,
      api_token: conn.assigns.api_token,
      agent_name: agent_name
    }

    # D137: best-effort, post-authorization; a failed stamp never fails create.
    ApiTokens.stamp_last_agent_name(creator.api_token, agent_name)

    case parse_id(task_params["column_id"] || get_default_column_id(board)) do
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

  defp do_update(conn, id_or_identifier, task_params) do
    board = conn.assigns.current_board

    case fetch_and_verify_task(id_or_identifier, board) do
      {:ok, task} ->
        if TaskParamFilter.column_change_attempted?(task_params, task) do
          reject_column_change(conn, task)
        else
          perform_api_task_update(conn, task, task_params)
        end

      error ->
        TaskErrors.handle_task_error(conn, error)
    end
  end

  # D109: live board-write re-check for the API create/update paths (W1430
  # in-depth), matching claim/complete/unclaim. Cross-board scope and
  # mass-assignment filtering already apply; this rejects a token whose user lost
  # :owner/:modify access but that escaped revocation.
  defp authorize_board_write(conn) do
    board = conn.assigns.current_board
    %{id: user_id} = conn.assigns.current_user

    if Boards.get_user_access(board.id, user_id) in [:owner, :modify] do
      :ok
    else
      {:error, :not_authorized_write}
    end
  end

  defp resolve_column_and_create(conn, board, column_id, task_params, creator) do
    # Board-scoped lookup unifies "no such column" and "column on other
    # board" into a single not_found response (W399).
    case Columns.get_column_for_board(column_id, board.id) do
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

    task_params_with_creator =
      build_task_params_with_creator(
        safe_task_params,
        creator.user,
        creator.api_token,
        creator.agent_name
      )

    if safe_child_tasks != [] do
      column
      |> Tasks.api_create_goal_with_tasks(task_params_with_creator, safe_child_tasks)
      |> handle_goal_creation(conn)
    else
      column
      |> Tasks.api_create_task(task_params_with_creator)
      |> handle_task_creation(conn)
    end
  end

  def batch_create(conn, %{"tasks" => _tasks}) do
    error_response =
      ErrorDocs.add_docs_to_error(
        %{
          error:
            "Invalid request format. The root key must be 'goals', not 'tasks'. See documentation for correct format.",
          example: %{
            goals: [
              %{
                title: "Goal Title",
                type: "goal",
                tasks: [
                  %{title: "Task 1", type: "work"},
                  %{title: "Task 2", type: "work"}
                ]
              }
            ]
          }
        },
        :batch_create_invalid_root_key
      )

    conn
    |> put_status(:unprocessable_entity)
    |> json(error_response)
  end

  def batch_create(conn, %{"goals" => goals} = params) do
    case authorize_board_write(conn) do
      :ok -> do_batch_create(conn, goals, params)
      error -> TaskErrors.handle_task_error(conn, error)
    end
  end

  def batch_create(conn, _params) do
    error_response =
      ErrorDocs.add_docs_to_error(
        %{
          error:
            "Invalid request format. Missing 'goals' key in request body. See documentation for correct format.",
          example: %{
            goals: [
              %{
                title: "Goal Title",
                type: "goal",
                tasks: [
                  %{title: "Task 1", type: "work"},
                  %{title: "Task 2", type: "work"}
                ]
              }
            ]
          }
        },
        :batch_create_missing_goals_key
      )

    conn
    |> put_status(:unprocessable_entity)
    |> json(error_response)
  end

  # Mirrors the live board-write re-check that create/2, update/2, and
  # after_goal enforce (D108/D109): a token whose user has only view/read-only
  # access — or whose owner/modify access was downgraded after the token was
  # issued — must not bulk-create goals via this endpoint. Called only after
  # authorize_board_write/1 passes, so no side effect runs for an unauthorized
  # caller.
  defp do_batch_create(conn, goals, params) do
    board = conn.assigns.current_board
    user = conn.assigns.current_user
    api_token = conn.assigns.api_token
    agent_name = params["agent_name"]

    stamp_agent_identity(conn, params)

    column_id = get_default_column_id(board)

    # Board-scoped lookup; default column should always exist on the board, so
    # this is defense-in-depth in case get_default_column_id returns nil/stale.
    case column_id && Columns.get_column_for_board(column_id, board.id) do
      nil ->
        TaskErrors.handle_task_error(conn, {:error, :not_found})

      column ->
        goals
        |> BatchGoalCreation.process_batch_goals(column, user, api_token, agent_name, conn)
        |> BatchGoalCreation.handle_batch_result(conn)
    end
  end

  def update(conn, %{"id" => _id_or_identifier, "data" => _data}) do
    error_response =
      ErrorDocs.add_docs_to_error(
        %{
          error:
            "Invalid request format. The request body key must be 'task', not 'data'. See documentation for correct format.",
          example: %{
            task: %{
              title: "Updated title",
              description: "Updated description",
              priority: "high"
            }
          }
        },
        :update_invalid_root_key
      )

    conn
    |> put_status(:unprocessable_entity)
    |> json(error_response)
  end

  def update(conn, %{"id" => id_or_identifier, "task" => task_params}) do
    case authorize_board_write(conn) do
      :ok -> do_update(conn, id_or_identifier, task_params)
      error -> TaskErrors.handle_task_error(conn, error)
    end
  end

  def update(conn, %{"id" => _id_or_identifier}) do
    error_response =
      ErrorDocs.add_docs_to_error(
        %{
          error:
            "Invalid request format. Missing 'task' key in request body. See documentation for correct format.",
          example: %{
            task: %{
              title: "Updated title",
              description: "Updated description",
              priority: "high"
            }
          }
        },
        :update_missing_task_key
      )

    conn
    |> put_status(:unprocessable_entity)
    |> json(error_response)
  end

  def next(conn, params) do
    board = conn.assigns.current_board
    user = conn.assigns.current_user
    api_token = conn.assigns.api_token
    agent_capabilities = api_token.agent_capabilities || []

    case Tasks.get_next_task(agent_capabilities, board.id, user.id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "No tasks available in Ready column matching your capabilities"})

      task ->
        emit_telemetry(conn, :next_task_fetched, %{task_id: task.id, priority: task.priority})

        render(conn, :show,
          task: task,
          agent_skills_version: params["skills_version"]
        )
    end
  end

  def claim(conn, params) do
    board = conn.assigns.current_board
    user = conn.assigns.current_user
    api_token = conn.assigns.api_token
    agent_capabilities = api_token.agent_capabilities || []
    task_identifier = params["identifier"]
    agent_name = params["agent_name"] || "Unknown"
    before_doing_result = params["before_doing_result"]
    agent_skills_version = params["skills_version"]

    stamp_agent_identity(conn, params)

    agent = %{
      capabilities: agent_capabilities,
      name: agent_name,
      api_token: api_token,
      skills_version: agent_skills_version
    }

    case Kanban.Hooks.Validator.validate_hook_execution(before_doing_result, "before_doing",
           blocking: true
         ) do
      :ok ->
        proceed_with_claim(conn, user, board, task_identifier, agent)

      {:error, reason} ->
        TaskErrors.handle_hook_validation_error(conn, "before_doing", reason)
    end
  end

  defp proceed_with_claim(conn, user, board, task_identifier, agent) do
    case Tasks.claim_next_task(agent.capabilities, user, board.id, task_identifier, agent.name) do
      {:ok, task, hook_info} ->
        render_claimed_task(conn, task, hook_info, task_identifier, agent)

      {:error, :no_tasks_available} ->
        handle_no_tasks_available(conn, task_identifier)

      {:error, :assigned_to_other_user} ->
        handle_assigned_to_other_user(conn, task_identifier)

      {:error, :not_authorized} ->
        TaskErrors.error_response(
          conn,
          :forbidden,
          "You do not have write access to claim tasks on this board",
          :not_authorized_to_claim
        )

      {:error, reason} ->
        handle_unexpected_claim_error(conn, reason,
          task_identifier: task_identifier,
          agent_name: agent.name
        )
    end
  end

  defp render_claimed_task(conn, task, hook_info, task_identifier, agent) do
    emit_telemetry(conn, :task_claimed, %{
      task_id: task.id,
      priority: task.priority,
      api_token_id: agent.api_token.id,
      specific_task: !!task_identifier
    })

    render(conn, :show,
      task: task,
      hook: hook_info,
      agent_skills_version: agent.skills_version
    )
  end

  # Logs the underlying reason server-side (changeset internals, internal
  # atoms, database errors, etc.) and returns a stable user-facing body
  # so the response does not leak implementation detail to API clients.
  # Exposed for testing.
  @doc false
  def handle_unexpected_claim_error(conn, reason, metadata) do
    Logger.error(
      "claim_next_task catch-all error: #{inspect(reason)}",
      Keyword.put(metadata, :reason, inspect(reason))
    )

    conn
    |> put_status(:internal_server_error)
    |> json(unexpected_claim_error_body())
  end

  @doc false
  def unexpected_claim_error_body do
    %{
      error: "internal_server_error",
      message: "Failed to claim task. Please retry; if the failure persists, contact support."
    }
  end

  def complete(conn, %{"id" => id_or_identifier} = params) do
    board = conn.assigns.current_board
    user = conn.assigns.current_user

    stamp_agent_identity(conn, params)

    with {:ok, task} <- fetch_and_verify_task(id_or_identifier, board),
         :ok <- validate_complete_preconditions(task, params) do
      proceed_with_complete(conn, task, user, params, build_complete_agent(conn, params))
    else
      error -> TaskErrors.handle_task_error(conn, error)
    end
  end

  # D137: remember the token's last-seen agent identity from the raw request
  # param — never the "Unknown" fallback the claim/complete paths default to.
  # Best-effort: a failed stamp never fails the parent request.
  defp stamp_agent_identity(conn, params) do
    ApiTokens.stamp_last_agent_name(conn.assigns.api_token, params["agent_name"])
  end

  defp validate_complete_preconditions(task, params) do
    with :ok <- validate_hook(params["after_doing_result"], "after_doing"),
         :ok <- validate_hook(params["before_review_result"], "before_review") do
      gate_completion_results(task, params)
    end
  end

  defp build_complete_agent(conn, params) do
    %{
      name: params["agent_name"] || "Unknown",
      api_token: conn.assigns.api_token,
      skills_version: params["skills_version"]
    }
  end

  defp gate_completion_results(task, params) do
    metadata = [task_id: task.id, agent_name: params["agent_name"]]

    case CompletionResultGate.gate(params, task: task, metadata: metadata) do
      :ok -> :ok
      {:warn, _failures} -> :ok
      {:reject, body} -> {:error, {:completion_validation_failed, body}}
    end
  end

  defp proceed_with_complete(conn, task, user, params, agent) do
    params_with_agent = maybe_add_completed_by_agent(params, agent.api_token, agent.name)

    case Tasks.complete_task(task, user, params_with_agent, agent.name) do
      {:ok, task, hooks} ->
        render_completed_task(conn, task, hooks, agent)

      {:error, :invalid_status} ->
        TaskErrors.error_response(
          conn,
          :unprocessable_entity,
          "Task must be in progress or blocked to complete",
          :invalid_status_for_complete
        )

      {:error, :not_authorized} ->
        TaskErrors.error_response(
          conn,
          :forbidden,
          "You can only complete tasks that you are assigned to",
          :not_authorized_to_complete
        )

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
    end
  end

  defp render_completed_task(conn, task, hooks, agent) do
    emit_telemetry(conn, :task_completed, %{
      task_id: task.id,
      time_spent_minutes: task.time_spent_minutes
    })

    render(conn, :show,
      task: task,
      hooks: hooks,
      agent_skills_version: agent.skills_version
    )
  end

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
      {:ok, task, value} -> render_changed_files_response(conn, task, value)
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

  defp render_changed_files_response(conn, task, value) do
    # `task` is already preloaded (column, assigned_to, …) because
    # `fetch_and_verify_task/2` loads via `get_task_for_view`; the no-op
    # `Ecto.Changeset.change/2` preserves those associations. No refetch.
    emit_telemetry(conn, :task_changed_files_persisted, %{
      task_id: task.id,
      file_count: length(value || [])
    })

    render(conn, :show, task: task)
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
        proceed_with_unclaim(conn, task, user, params["reason"])

      error ->
        TaskErrors.handle_task_error(conn, error)
    end
  end

  defp proceed_with_unclaim(conn, task, user, reason) do
    case Tasks.unclaim_task(task, user, reason) do
      {:ok, task} ->
        emit_telemetry(conn, :task_unclaimed, %{task_id: task.id, reason: reason})
        render(conn, :show, task: task)

      {:error, :not_authorized} ->
        TaskErrors.error_response(
          conn,
          :forbidden,
          "You can only unclaim tasks that you claimed",
          :not_authorized_to_unclaim
        )

      {:error, :not_claimed} ->
        TaskErrors.error_response(
          conn,
          :unprocessable_entity,
          "Task is not currently claimed",
          :task_not_claimed
        )

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
    end
  end

  def mark_reviewed(conn, %{"id" => id_or_identifier} = params) do
    board = conn.assigns.current_board
    user = conn.assigns.current_user

    with {:ok, task} <- fetch_and_verify_task(id_or_identifier, board),
         :ok <- validate_hook(params["after_review_result"], "after_review") do
      proceed_with_mark_reviewed(conn, task, user)
    else
      error -> TaskErrors.handle_task_error(conn, error)
    end
  end

  defp proceed_with_mark_reviewed(conn, task, user) do
    task
    |> Tasks.mark_reviewed(user)
    |> render_mark_reviewed_result(conn)
  end

  defp render_mark_reviewed_result({:ok, task, hooks}, conn) when is_list(hooks),
    do: render_reviewed_task(conn, task, hooks: hooks)

  defp render_mark_reviewed_result({:ok, task}, conn), do: render_reviewed_task(conn, task)

  defp render_mark_reviewed_result({:error, %Ecto.Changeset{} = changeset}, conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> render(:error, changeset: changeset)
  end

  defp render_mark_reviewed_result({:error, reason}, conn) do
    {message, code} = TaskErrors.mark_reviewed_error(reason)
    TaskErrors.error_response(conn, :unprocessable_entity, message, code)
  end

  defp render_reviewed_task(conn, task, opts \\ []) do
    event_name =
      if task.status == :completed, do: :task_marked_done, else: :task_returned_to_doing

    emit_telemetry(conn, event_name, %{
      task_id: task.id,
      review_status: task.review_status
    })

    render(conn, :show, [{:task, task} | opts])
  end

  def mark_done(conn, %{"id" => id_or_identifier}) do
    board = conn.assigns.current_board
    user = conn.assigns.current_user

    case fetch_and_verify_task(id_or_identifier, board) do
      {:ok, task} -> proceed_with_mark_done(conn, task, user)
      error -> TaskErrors.handle_task_error(conn, error)
    end
  end

  defp proceed_with_mark_done(conn, task, user) do
    case Tasks.mark_done(task, user) do
      {:ok, task} ->
        emit_telemetry(conn, :task_marked_done, %{task_id: task.id})
        render(conn, :show, task: task)

      {:error, :invalid_column} ->
        TaskErrors.error_response(
          conn,
          :unprocessable_entity,
          "Task must be in Review column to mark as done",
          :invalid_column_for_mark_done
        )

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
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
           fetch_verify_and_authorize_after_goal(
             id_or_identifier,
             board,
             conn.assigns.current_user
           ),
         :ok <- validate_after_goal_target(task),
         {:ok, attempt} <- validate_after_goal_result(params) do
      proceed_with_after_goal(conn, task, attempt)
    else
      error -> TaskErrors.handle_task_error(conn, error)
    end
  end

  # D108: parity with claim/complete/mark_reviewed/mark_done — require live
  # board-write access so a downgraded or leaked token cannot promote a goal to
  # Done. Cross-board scope is already enforced by fetch_and_verify_task; this is
  # the in-depth W1430 re-check the sibling endpoints apply.
  defp fetch_verify_and_authorize_after_goal(id_or_identifier, board, %{id: user_id}) do
    with {:ok, task} <- fetch_and_verify_task(id_or_identifier, board) do
      if Boards.get_user_access(board.id, user_id) in [:owner, :modify] do
        {:ok, task}
      else
        {:error, :not_authorized_after_goal}
      end
    end
  end

  defp validate_after_goal_target(%Kanban.Tasks.Task{type: :goal} = task) do
    case task.after_goal_status do
      status when status in [:pending, :succeeded] -> :ok
      _ -> {:error, :after_goal_not_started}
    end
  end

  defp validate_after_goal_target(_), do: {:error, :after_goal_not_a_goal}

  defp validate_after_goal_result(%{
         "exit_code" => exit_code,
         "output" => output,
         "duration_ms" => duration_ms
       })
       when is_integer(exit_code) and is_binary(output) and is_integer(duration_ms) and
              duration_ms >= 0 do
    {:ok,
     %{
       "exit_code" => exit_code,
       "output" => output,
       "duration_ms" => duration_ms,
       "reported_at" => DateTime.utc_now() |> DateTime.to_iso8601()
     }}
  end

  defp validate_after_goal_result(_), do: {:error, :invalid_after_goal_result}

  defp proceed_with_after_goal(conn, task, attempt) do
    case Tasks.report_after_goal(task, attempt) do
      {:ok, updated_goal} ->
        emit_telemetry(conn, :after_goal_reported, %{
          task_id: updated_goal.id,
          exit_code: attempt["exit_code"]
        })

        render(conn, :show, task: updated_goal)

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
    end
  end

  def dependencies(conn, %{"id" => id_or_identifier}) do
    board = conn.assigns.current_board

    case fetch_and_verify_task(id_or_identifier, board) do
      {:ok, task} ->
        dependency_tree = Tasks.get_dependency_tree(task)
        emit_telemetry(conn, :dependencies_fetched, %{task_id: task.id})

        json(conn, %{
          task: render_task_summary(task),
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
          task: render_task_summary(task),
          dependents: Enum.map(dependent_tasks, &render_task_summary/1)
        })

      error ->
        TaskErrors.handle_task_error(conn, error)
    end
  end

  def tree(conn, %{"id" => id_or_identifier}) do
    board = conn.assigns.current_board

    case fetch_and_verify_task(id_or_identifier, board) do
      {:ok, task} ->
        tree_data = Tasks.get_task_tree(task.id, board.id)
        emit_telemetry(conn, :task_tree_fetched, %{task_id: task.id})
        render(conn, :tree, tree: tree_data)

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

  defp get_task_by_id_or_identifier(id_or_identifier, board) do
    case Integer.parse(id_or_identifier) do
      {id, ""} ->
        # It's a numeric ID
        Tasks.get_task_for_view(id)

      _ ->
        # It's an identifier like "W14"
        columns = Columns.list_columns(board)
        column_ids = Enum.map(columns, & &1.id)

        Tasks.get_task_by_identifier_for_view(id_or_identifier, column_ids)
    end
  end

  defp fetch_task_by_id_or_identifier(id_or_identifier, board) do
    case get_task_by_id_or_identifier(id_or_identifier, board) do
      nil -> {:error, :not_found}
      task -> {:ok, task}
    end
  end

  defp fetch_and_verify_task(id_or_identifier, board) do
    with {:ok, task} <- fetch_task_by_id_or_identifier(id_or_identifier, board),
         :ok <- verify_board_ownership(task, board) do
      {:ok, task}
    end
  end

  defp verify_board_ownership(%{column: %{board_id: board_id}}, %{id: board_id}), do: :ok
  defp verify_board_ownership(_, _), do: {:error, :forbidden}

  defp validate_hook(result, hook_name) do
    case Kanban.Hooks.Validator.validate_hook_execution(result, hook_name, blocking: true) do
      :ok -> :ok
      {:error, reason} -> {:error, {:hook_failed, hook_name, reason}}
    end
  end

  @doc false
  def build_task_params_with_creator(task_params, user, api_token, agent_name) do
    task_params
    |> Map.put("created_by_id", user.id)
    |> maybe_add_created_by_agent(api_token, agent_name)
    |> Map.delete("column_id")
  end

  defp handle_task_creation({:ok, task}, conn) do
    task = Tasks.get_task_for_view!(task.id)
    emit_telemetry(conn, :task_created, %{task_id: task.id})

    conn
    |> put_status(:created)
    |> put_resp_header("location", ~p"/api/tasks/#{task}")
    |> render(:show, task: task)
  end

  defp handle_task_creation({:error, %Ecto.Changeset{} = changeset}, conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> render(:error, changeset: changeset)
  end

  defp handle_goal_creation({:ok, %{goal: goal, child_tasks: child_tasks}}, conn) do
    goal = Tasks.get_task_for_view!(goal.id)

    emit_telemetry(conn, :goal_created, %{
      goal_id: goal.id,
      child_task_count: length(child_tasks)
    })

    conn
    |> put_status(:created)
    |> put_resp_header("location", ~p"/api/tasks/#{goal}")
    |> json(%{
      goal: render_goal_with_children(goal),
      child_tasks: Enum.map(child_tasks, &render_task_summary/1)
    })
  end

  defp handle_goal_creation({:error, _operation, %Ecto.Changeset{} = changeset}, conn) do
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

  defp get_default_column_id(board) do
    columns = Columns.list_columns(board)

    backlog = Enum.find(columns, fn col -> col.name == "Backlog" end)
    ready = Enum.find(columns, fn col -> col.name == "Ready" end)

    cond do
      backlog -> backlog.id
      ready -> ready.id
      true -> List.first(columns).id
    end
  end

  # Exposed (with build_task_params_with_creator/4, log_create_forbidden_fields/3,
  # render_goal_with_children/1, render_task_summary/1) so KanbanWeb.API.BatchGoalCreation
  # can compose them; they remain owned here because the single-create and
  # dependency-listing actions share them.
  @doc false
  def emit_telemetry(conn, event_name, metadata) do
    :telemetry.execute(
      [:kanban, :api, event_name],
      %{count: 1},
      Map.merge(metadata, %{
        board_id: conn.assigns.current_board.id,
        user_id: conn.assigns.current_user.id,
        path: conn.request_path,
        method: conn.method
      })
    )
  end

  @doc false
  def render_task_summary(task) do
    %{
      id: task.id,
      identifier: task.identifier,
      title: task.title,
      status: task.status,
      priority: task.priority,
      complexity: task.complexity,
      dependencies: task.dependencies || [],
      created_by_agent: task.created_by_agent
    }
  end

  defp render_dependency_tree(dependencies) do
    Enum.map(dependencies, fn dep_tree ->
      %{
        task: render_task_summary(dep_tree.task),
        dependencies: render_dependency_tree(dep_tree.dependencies)
      }
    end)
  end

  # D137 resolution order: explicit created_by_agent field → token agent_model
  # ("ai_agent:<model>") → top-level agent_name param → token last_agent_name
  # → unset (the agents feed renders unattributed rows as "?").
  defp maybe_add_created_by_agent(task_params, api_token, agent_name) do
    if Map.has_key?(task_params, "created_by_agent") do
      task_params
    else
      case resolve_created_by_agent(api_token, agent_name) do
        nil -> task_params
        agent -> Map.put(task_params, "created_by_agent", agent)
      end
    end
  end

  defp resolve_created_by_agent(api_token, agent_name) do
    cond do
      api_token.agent_model -> "ai_agent:#{api_token.agent_model}"
      ApiTokens.usable_agent_name?(agent_name) -> agent_name
      ApiTokens.usable_agent_name?(api_token.last_agent_name) -> api_token.last_agent_name
      true -> nil
    end
  end

  defp maybe_add_completed_by_agent(task_params, api_token, agent_name) do
    case api_token.agent_model do
      nil -> Map.put(task_params, "completed_by_agent", agent_name)
      agent_model -> Map.put(task_params, "completed_by_agent", "ai_agent:#{agent_model}")
    end
  end

  defp handle_no_tasks_available(conn, task_identifier) do
    error_message =
      if task_identifier do
        "Task '#{task_identifier}' is not available to claim. It may be blocked by dependencies, already claimed, require capabilities you don't have, or not exist on this board."
      else
        "No tasks available to claim matching your capabilities. All tasks in Ready column are either blocked, already claimed, or require capabilities you don't have."
      end

    error_response =
      ErrorDocs.add_docs_to_error(
        %{error: error_message},
        if(task_identifier, do: :task_not_claimable, else: :no_tasks_available),
        identifier: task_identifier
      )

    conn
    |> put_status(:conflict)
    |> json(error_response)
  end

  defp handle_assigned_to_other_user(conn, task_identifier) do
    error_message =
      if task_identifier do
        "Task '#{task_identifier}' is assigned to a different user. Only the assigned user can claim it."
      else
        "This task is assigned to a different user. Only the assigned user can claim it."
      end

    error_response =
      ErrorDocs.add_docs_to_error(
        %{error: error_message},
        :assigned_to_other_user,
        identifier: task_identifier
      )

    conn
    |> put_status(:forbidden)
    |> json(error_response)
  end

  defp reject_column_change(conn, task) do
    emit_telemetry(conn, :task_update_column_change_forbidden, %{task_id: task.id})

    TaskErrors.error_response(
      conn,
      :forbidden,
      "Agents cannot move tasks between columns via update. Use the workflow endpoints (claim, complete, mark_reviewed, mark_done) to transition tasks.",
      :column_change_forbidden
    )
  end

  defp perform_api_task_update(conn, task, task_params) do
    {safe_params, rejected_fields} = TaskParamFilter.filter_forbidden_update_fields(task_params)

    log_update_forbidden_fields(conn, task, rejected_fields)

    case Tasks.api_update_task(task, safe_params) do
      {:ok, updated_task} ->
        updated_task = Tasks.get_task_for_view!(updated_task.id)
        emit_telemetry(conn, :task_updated, %{task_id: updated_task.id})
        render(conn, :show, task: updated_task)

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
    end
  end

  # Emits the update-path mass-assignment audit log (via TaskParamFilter) and,
  # when a forbidden field was rejected, the companion telemetry event.
  defp log_update_forbidden_fields(conn, task, rejected_fields) do
    TaskParamFilter.log_update_mass_assignment(task.id, rejected_fields, actor_user_id(conn))

    if rejected_fields != [] do
      emit_telemetry(conn, :task_update_forbidden_fields_filtered, %{
        task_id: task.id,
        fields: rejected_fields
      })
    end
  end

  # Emits the create-path mass-assignment audit log (via TaskParamFilter) and,
  # when a forbidden field was rejected, the companion telemetry event. The
  # audit Logger line lives in TaskParamFilter; telemetry stays here because
  # emit_telemetry/3 is controller-wide infra keyed off conn.
  @doc false
  def log_create_forbidden_fields(conn, goal_fields, child_fields) do
    TaskParamFilter.log_create_mass_assignment(goal_fields, child_fields, actor_user_id(conn))

    if goal_fields != [] or child_fields != [] do
      emit_telemetry(conn, :task_create_forbidden_fields_filtered, %{
        goal_fields: goal_fields,
        child_fields: child_fields
      })
    end
  end

  defp actor_user_id(conn), do: conn.assigns[:current_user] && conn.assigns.current_user.id

  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> {:ok, int_id}
      _ -> :error
    end
  end

  defp parse_id(_), do: :error
end
