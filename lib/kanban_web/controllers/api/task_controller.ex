defmodule KanbanWeb.API.TaskController do
  use KanbanWeb, :controller

  alias Kanban.Columns
  alias Kanban.Tasks
  alias KanbanWeb.API.ErrorDocs

  action_fallback KanbanWeb.API.FallbackController

  def index(conn, params) do
    board = conn.assigns.current_board

    column_id = params["column_id"]

    if column_id do
      column = Columns.get_column!(column_id)

      if column.board_id != board.id do
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Column does not belong to this board"})
      else
        tasks = Tasks.list_tasks(column)
        emit_telemetry(conn, :task_listed, %{count: length(tasks)})
        render(conn, :index, tasks: tasks)
      end
    else
      columns = Columns.list_columns(board)
      tasks = Enum.flat_map(columns, &Tasks.list_tasks/1)
      emit_telemetry(conn, :task_listed, %{count: length(tasks)})
      render(conn, :index, tasks: tasks)
    end
  end

  def show(conn, %{"id" => id_or_identifier}) do
    board = conn.assigns.current_board

    case get_task_by_id_or_identifier(id_or_identifier, board) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Task not found"})

      task ->
        if task.column.board_id != board.id do
          conn
          |> put_status(:forbidden)
          |> json(%{error: "Task does not belong to this board"})
        else
          render(conn, :show, task: task)
        end
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

  def create(conn, %{"task" => task_params}) do
    board = conn.assigns.current_board
    user = conn.assigns.current_user
    api_token = conn.assigns.api_token

    column_id = task_params["column_id"] || get_default_column_id(board)
    column = Columns.get_column!(column_id)

    if column.board_id != board.id do
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Column does not belong to this board"})
    else
      task_params_with_creator = build_task_params_with_creator(task_params, user, api_token)

      child_tasks = Map.get(task_params, "tasks", [])

      if child_tasks != [] do
        column
        |> Tasks.create_goal_with_tasks(task_params_with_creator, child_tasks)
        |> handle_goal_creation(conn)
      else
        column
        |> Tasks.create_task(task_params_with_creator)
        |> handle_task_creation(conn)
      end
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

  def batch_create(conn, %{"goals" => goals}) do
    board = conn.assigns.current_board
    user = conn.assigns.current_user
    api_token = conn.assigns.api_token

    column_id = get_default_column_id(board)
    column = Columns.get_column!(column_id)

    if column.board_id != board.id do
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Column does not belong to this board"})
    else
      goals
      |> process_batch_goals(column, user, api_token, conn)
      |> handle_batch_result(conn)
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
    board = conn.assigns.current_board

    case get_task_by_id_or_identifier(id_or_identifier, board) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Task not found"})

      task ->
        if task.column.board_id != board.id do
          conn
          |> put_status(:forbidden)
          |> json(%{error: "Task does not belong to this board"})
        else
          case Tasks.update_task(task, task_params) do
            {:ok, task} ->
              task = Tasks.get_task_for_view!(task.id)
              emit_telemetry(conn, :task_updated, %{task_id: task.id})
              render(conn, :show, task: task)

            {:error, %Ecto.Changeset{} = changeset} ->
              conn
              |> put_status(:unprocessable_entity)
              |> render(:error, changeset: changeset)
          end
        end
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

  def next(conn, _params) do
    board = conn.assigns.current_board
    api_token = conn.assigns.api_token
    agent_capabilities = api_token.agent_capabilities || []

    case Tasks.get_next_task(agent_capabilities, board.id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "No tasks available in Ready column matching your capabilities"})

      task ->
        emit_telemetry(conn, :next_task_fetched, %{task_id: task.id, priority: task.priority})
        render(conn, :show, task: task)
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

    case Kanban.Hooks.Validator.validate_hook_execution(before_doing_result, "before_doing",
           blocking: true
         ) do
      :ok ->
        proceed_with_claim(
          conn,
          agent_capabilities,
          user,
          board,
          task_identifier,
          agent_name,
          api_token
        )

      {:error, reason} ->
        handle_hook_validation_error(conn, "before_doing", reason)
    end
  end

  defp proceed_with_claim(
         conn,
         agent_capabilities,
         user,
         board,
         task_identifier,
         agent_name,
         api_token
       ) do
    case Tasks.claim_next_task(agent_capabilities, user, board.id, task_identifier, agent_name) do
      {:ok, task, hook_info} ->
        emit_telemetry(conn, :task_claimed, %{
          task_id: task.id,
          priority: task.priority,
          api_token_id: api_token.id,
          specific_task: !!task_identifier
        })

        render(conn, :show, task: task, hook: hook_info)

      {:error, :no_tasks_available} ->
        handle_no_tasks_available(conn, task_identifier)

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to claim task", reason: inspect(reason)})
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.ABCSize
  def complete(conn, %{"id" => id_or_identifier} = params) do
    board = conn.assigns.current_board
    user = conn.assigns.current_user
    api_token = conn.assigns.api_token
    task = get_task_by_id_or_identifier!(id_or_identifier, board)
    agent_name = params["agent_name"] || "Unknown"
    after_doing_result = params["after_doing_result"]
    before_review_result = params["before_review_result"]

    if task.column.board_id != board.id do
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Task does not belong to this board"})
    else
      with :ok <-
             Kanban.Hooks.Validator.validate_hook_execution(after_doing_result, "after_doing",
               blocking: true
             ),
           :ok <-
             Kanban.Hooks.Validator.validate_hook_execution(before_review_result, "before_review",
               blocking: true
             ) do
        proceed_with_complete(conn, task, user, params, api_token, agent_name)
      else
        {:error, reason} ->
          hook_name =
            if String.contains?(reason, "after_doing"), do: "after_doing", else: "before_review"

          handle_hook_validation_error(conn, hook_name, reason)
      end
    end
  end

  defp proceed_with_complete(conn, task, user, params, api_token, agent_name) do
    params_with_agent = maybe_add_completed_by_agent(params, api_token)

    case Tasks.complete_task(task, user, params_with_agent, agent_name) do
      {:ok, task, hooks} ->
        emit_telemetry(conn, :task_completed, %{
          task_id: task.id,
          time_spent_minutes: task.time_spent_minutes
        })

        render(conn, :show, task: task, hooks: hooks)

      {:error, :invalid_status} ->
        error_response =
          ErrorDocs.add_docs_to_error(
            %{error: "Task must be in progress or blocked to complete"},
            :invalid_status_for_complete
          )

        conn
        |> put_status(:unprocessable_entity)
        |> json(error_response)

      {:error, :not_authorized} ->
        error_response =
          ErrorDocs.add_docs_to_error(
            %{error: "You can only complete tasks that you are assigned to"},
            :not_authorized_to_complete
          )

        conn
        |> put_status(:forbidden)
        |> json(error_response)

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
    end
  end

  def unclaim(conn, %{"id" => id_or_identifier} = params) do
    board = conn.assigns.current_board
    user = conn.assigns.current_user
    task = get_task_by_id_or_identifier!(id_or_identifier, board)
    reason = params["reason"]

    if task.column.board_id != board.id do
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Task does not belong to this board"})
    else
      case Tasks.unclaim_task(task, user, reason) do
        {:ok, task} ->
          emit_telemetry(conn, :task_unclaimed, %{task_id: task.id, reason: reason})
          render(conn, :show, task: task)

        {:error, :not_authorized} ->
          error_response =
            ErrorDocs.add_docs_to_error(
              %{error: "You can only unclaim tasks that you claimed"},
              :not_authorized_to_unclaim
            )

          conn
          |> put_status(:forbidden)
          |> json(error_response)

        {:error, :not_claimed} ->
          error_response =
            ErrorDocs.add_docs_to_error(
              %{error: "Task is not currently claimed"},
              :task_not_claimed
            )

          conn
          |> put_status(:unprocessable_entity)
          |> json(error_response)

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> render(:error, changeset: changeset)
      end
    end
  end

  # credo:disable-for-lines:57
  def mark_reviewed(conn, %{"id" => id_or_identifier} = params) do
    board = conn.assigns.current_board
    user = conn.assigns.current_user
    task = get_task_by_id_or_identifier!(id_or_identifier, board)
    after_review_result = params["after_review_result"]

    if task.column.board_id != board.id do
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Task does not belong to this board"})
    else
      case Kanban.Hooks.Validator.validate_hook_execution(after_review_result, "after_review",
             blocking: true
           ) do
        :ok ->
          proceed_with_mark_reviewed(conn, task, user)

        {:error, reason} ->
          handle_hook_validation_error(conn, "after_review", reason)
      end
    end
  end

  defp proceed_with_mark_reviewed(conn, task, user) do
    case Tasks.mark_reviewed(task, user) do
      {:ok, task, hook_info} ->
        event_name =
          if task.status == :completed, do: :task_marked_done, else: :task_returned_to_doing

        emit_telemetry(conn, event_name, %{
          task_id: task.id,
          review_status: task.review_status
        })

        render(conn, :show, task: task, hook: hook_info)

      {:ok, task} ->
        event_name =
          if task.status == :completed, do: :task_marked_done, else: :task_returned_to_doing

        emit_telemetry(conn, event_name, %{
          task_id: task.id,
          review_status: task.review_status
        })

        render(conn, :show, task: task)

      {:error, :invalid_column} ->
        error_response =
          ErrorDocs.add_docs_to_error(
            %{error: "Task must be in Review column to mark as reviewed"},
            :invalid_column_for_review
          )

        conn
        |> put_status(:unprocessable_entity)
        |> json(error_response)

      {:error, :review_not_performed} ->
        error_response =
          ErrorDocs.add_docs_to_error(
            %{error: "Task must have a review status before being marked as reviewed"},
            :review_not_performed
          )

        conn
        |> put_status(:unprocessable_entity)
        |> json(error_response)

      {:error, :invalid_review_status} ->
        error_response =
          ErrorDocs.add_docs_to_error(
            %{
              error:
                "Invalid review status. Must be 'approved', 'changes_requested', or 'rejected'"
            },
            :invalid_review_status
          )

        conn
        |> put_status(:unprocessable_entity)
        |> json(error_response)

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
    end
  end

  def mark_done(conn, %{"id" => id_or_identifier}) do
    board = conn.assigns.current_board
    user = conn.assigns.current_user
    task = get_task_by_id_or_identifier!(id_or_identifier, board)

    if task.column.board_id != board.id do
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Task does not belong to this board"})
    else
      case Tasks.mark_done(task, user) do
        {:ok, task} ->
          emit_telemetry(conn, :task_marked_done, %{task_id: task.id})
          render(conn, :show, task: task)

        {:error, :invalid_column} ->
          error_response =
            ErrorDocs.add_docs_to_error(
              %{error: "Task must be in Review column to mark as done"},
              :invalid_column_for_mark_done
            )

          conn
          |> put_status(:unprocessable_entity)
          |> json(error_response)

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> render(:error, changeset: changeset)
      end
    end
  end

  def dependencies(conn, %{"id" => id_or_identifier}) do
    board = conn.assigns.current_board
    task = get_task_by_id_or_identifier!(id_or_identifier, board)

    if task.column.board_id != board.id do
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Task does not belong to this board"})
    else
      dependency_tree = Tasks.get_dependency_tree(task)
      emit_telemetry(conn, :dependencies_fetched, %{task_id: task.id})

      json(conn, %{
        task: render_task_summary(task),
        dependencies: render_dependency_tree(dependency_tree.dependencies)
      })
    end
  end

  def dependents(conn, %{"id" => id_or_identifier}) do
    board = conn.assigns.current_board
    task = get_task_by_id_or_identifier!(id_or_identifier, board)

    if task.column.board_id != board.id do
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Task does not belong to this board"})
    else
      dependent_tasks = Tasks.get_dependent_tasks(task)

      emit_telemetry(conn, :dependents_fetched, %{
        task_id: task.id,
        count: length(dependent_tasks)
      })

      json(conn, %{
        task: render_task_summary(task),
        dependents: Enum.map(dependent_tasks, &render_task_summary/1)
      })
    end
  end

  def tree(conn, %{"id" => id_or_identifier}) do
    board = conn.assigns.current_board
    task = get_task_by_id_or_identifier!(id_or_identifier, board)

    if task.column.board_id != board.id do
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Task does not belong to this board"})
    else
      tree_data = Tasks.get_task_tree(task.id)
      emit_telemetry(conn, :task_tree_fetched, %{task_id: task.id})

      render(conn, :tree, tree: tree_data)
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

        Tasks.get_task_by_identifier_for_view!(id_or_identifier, column_ids)
    end
  end

  defp get_task_by_id_or_identifier!(id_or_identifier, board) do
    case get_task_by_id_or_identifier(id_or_identifier, board) do
      nil -> raise Ecto.NoResultsError, queryable: Kanban.Tasks.Task
      task -> task
    end
  end

  defp build_task_params_with_creator(task_params, user, api_token) do
    task_params
    |> Map.put("created_by_id", user.id)
    |> maybe_add_created_by_agent(api_token)
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

  defp render_goal_with_children(goal) do
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

  defp emit_telemetry(conn, event_name, metadata) do
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

  defp render_task_summary(task) do
    %{
      id: task.id,
      identifier: task.identifier,
      title: task.title,
      status: task.status,
      priority: task.priority,
      complexity: task.complexity,
      dependencies: task.dependencies || []
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

  defp maybe_add_created_by_agent(task_params, api_token) do
    case api_token.agent_model do
      nil -> task_params
      agent_model -> Map.put(task_params, "created_by_agent", "ai_agent:#{agent_model}")
    end
  end

  defp maybe_add_completed_by_agent(task_params, api_token) do
    case api_token.agent_model do
      nil -> task_params
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

  defp translate_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp process_batch_goals(goals, column, user, api_token, conn) do
    goals
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {goal_params, index}, {:ok, acc} ->
      create_single_goal_in_batch(goal_params, index, column, user, api_token, conn, acc)
    end)
  end

  defp create_single_goal_in_batch(goal_params, index, column, user, api_token, conn, acc) do
    task_params_with_creator = build_task_params_with_creator(goal_params, user, api_token)
    child_tasks = Map.get(goal_params, "tasks", [])

    case Tasks.create_goal_with_tasks(column, task_params_with_creator, child_tasks) do
      {:ok, %{goal: goal, child_tasks: created_child_tasks}} ->
        handle_successful_goal_creation(goal, created_child_tasks, index, conn, acc)

      {:error, _operation, changeset} ->
        {:halt, {:error, index, changeset}}
    end
  end

  defp handle_successful_goal_creation(goal, created_child_tasks, index, conn, acc) do
    goal = Tasks.get_task_for_view!(goal.id)

    emit_telemetry(conn, :goal_created, %{
      goal_id: goal.id,
      child_task_count: length(created_child_tasks),
      batch: true,
      batch_index: index
    })

    result = %{
      goal: render_goal_with_children(goal),
      child_tasks: Enum.map(created_child_tasks, &render_task_summary/1)
    }

    {:cont, {:ok, [result | acc]}}
  end

  defp handle_batch_result({:ok, created_goals}, conn) do
    emit_telemetry(conn, :batch_goals_created, %{
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

  defp handle_batch_result({:error, index, changeset}, conn)
       when is_struct(changeset, Ecto.Changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "Failed to create goal at index #{index}",
      index: index,
      details: translate_changeset_errors(changeset)
    })
  end

  defp handle_batch_result({:error, index, :wip_limit_reached}, conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "WIP limit reached while creating goal at index #{index}",
      index: index
    })
  end

  defp handle_hook_validation_error(conn, hook_name, reason) do
    error_response =
      ErrorDocs.add_docs_to_error(
        %{
          error: reason,
          hook: hook_name,
          required_format: %{
            "#{hook_name}_result" => %{
              exit_code: 0,
              output: "Hook execution output",
              duration_ms: 1234
            }
          }
        },
        :hook_validation_failed
      )

    conn
    |> put_status(:unprocessable_entity)
    |> json(error_response)
  end
end
