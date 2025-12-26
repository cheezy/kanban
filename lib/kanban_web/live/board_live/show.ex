defmodule KanbanWeb.BoardLive.Show do
  use KanbanWeb, :live_view

  alias Kanban.ApiTokens
  alias Kanban.Boards
  alias Kanban.Columns
  alias Kanban.Tasks

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       viewing_task_id: nil,
       show_task_modal: false,
       tasks_version: :os.system_time(:millisecond)
     )}
  end

  @impl true
  def handle_params(%{"id" => id, "column_id" => column_id, "task_id" => task_id}, _, socket) do
    user = socket.assigns.current_scope.user
    board = Boards.get_board!(id, user)
    user_access = Boards.get_user_access(board.id, user.id)
    columns = Columns.list_columns(board)
    column = Columns.get_column!(column_id)
    task = Tasks.get_task!(task_id)

    subscribe_to_board_updates(socket, board.id)

    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:board, board)
     |> assign(:user_access, user_access)
     |> assign(:can_modify, user_access in [:owner, :modify])
     |> assign(:is_owner, user_access == :owner)
     |> assign(:field_visibility, board.field_visibility || %{})
     |> assign(:column, column)
     |> assign(:task, task)
     |> assign(:has_columns, not Enum.empty?(columns))
     |> stream(:columns, columns, reset: true)
     |> load_tasks_for_columns(columns)}
  end

  def handle_params(%{"id" => id, "column_id" => column_id}, _, socket) do
    user = socket.assigns.current_scope.user
    board = Boards.get_board!(id, user)
    user_access = Boards.get_user_access(board.id, user.id)

    subscribe_to_board_updates(socket, board.id)

    case check_column_action_authorization(socket.assigns.live_action, user_access, board) do
      :ok ->
        assign_board_with_column(socket, board, user_access, column_id)

      {:error, message} ->
        {:noreply,
         socket
         |> put_flash(:error, message)
         |> push_patch(to: ~p"/boards/#{board}")}
    end
  end

  def handle_params(%{"id" => id, "task_id" => task_id}, _, socket) do
    user = socket.assigns.current_scope.user
    board = Boards.get_board!(id, user)
    user_access = Boards.get_user_access(board.id, user.id)
    columns = Columns.list_columns(board)
    task = Tasks.get_task!(task_id)

    subscribe_to_board_updates(socket, board.id)

    socket =
      socket
      |> assign(:page_title, page_title(socket.assigns.live_action))
      |> assign(:board, board)
      |> assign(:user_access, user_access)
      |> assign(:can_modify, user_access in [:owner, :modify])
      |> assign(:is_owner, user_access == :owner)
      |> assign(:field_visibility, board.field_visibility || %{})
      |> assign(:task, task)
      |> assign(:has_columns, not Enum.empty?(columns))
      |> assign(:viewing_task_id, nil)
      |> assign(:show_task_modal, false)
      |> stream(:columns, columns, reset: true)

    socket =
      if Map.has_key?(socket.assigns, :tasks_by_column) do
        socket
      else
        load_tasks_for_columns(socket, columns)
      end

    {:noreply, socket}
  end

  def handle_params(%{"id" => id}, _, socket) when socket.assigns.live_action == :api_tokens do
    user = socket.assigns.current_scope.user
    board = Boards.get_board!(id, user)
    user_access = Boards.get_user_access(board.id, user.id)

    subscribe_to_board_updates(socket, board.id)

    cond do
      not board.ai_optimized_board ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("API tokens are only available for AI Optimized boards"))
         |> push_patch(to: ~p"/boards/#{board}")}

      user_access in [:owner, :modify] ->
        assign_api_tokens_state(socket, board, user_access)

      true ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You don't have permission to manage API tokens"))
         |> push_patch(to: ~p"/boards/#{board}")}
    end
  end

  def handle_params(%{"id" => id}, _, socket) do
    user = socket.assigns.current_scope.user
    board = Boards.get_board!(id, user)
    user_access = Boards.get_user_access(board.id, user.id)

    subscribe_to_board_updates(socket, board.id)

    case check_new_column_authorization(socket.assigns.live_action, user_access, board) do
      :ok ->
        assign_board_state(socket, board, user_access)

      {:error, message} ->
        {:noreply,
         socket
         |> put_flash(:error, message)
         |> push_patch(to: ~p"/boards/#{board}")}
    end
  end

  @impl true
  def handle_event("delete_column", %{"id" => id}, socket) do
    cond do
      socket.assigns.user_access != :owner ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Only the board owner can delete columns"))}

      socket.assigns.board.ai_optimized_board ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Cannot delete columns on AI optimized boards"))}

      true ->
        column = Columns.get_column!(id)

        case Columns.delete_column(column) do
          {:ok, _column} ->
            columns = Columns.list_columns(socket.assigns.board)

            {:noreply,
             socket
             |> put_flash(:info, gettext("Column deleted successfully"))
             |> assign(:has_columns, not Enum.empty?(columns))
             |> stream_delete(:columns, column)}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to delete column"))}
        end
    end
  end

  @impl true
  def handle_event("view_task", %{"id" => id}, socket) do
    require Logger
    task_id = String.to_integer(id)
    Logger.debug("view_task event: task_id=#{task_id}, scheduling modal show")
    Process.send_after(self(), {:show_task_modal, task_id}, 100)
    {:noreply, assign(socket, viewing_task_id: task_id, show_task_modal: false)}
  end

  @impl true
  def handle_event("close_task_view", _, socket) do
    require Logger
    Logger.debug("close_task_view event")
    {:noreply, assign(socket, viewing_task_id: nil, show_task_modal: false)}
  end

  @impl true
  def handle_event("delete_task", %{"id" => id}, socket) do
    task = Tasks.get_task!(id)

    case Tasks.delete_task(task) do
      {:ok, _deleted_task} ->
        # Reload columns and tasks from database
        columns = Columns.list_columns(socket.assigns.board)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Task deleted successfully"))
         |> stream(:columns, columns, reset: true)
         |> load_tasks_for_columns(columns)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to delete task"))}
    end
  end

  @impl true
  def handle_event(
        "move_task",
        %{
          "task_id" => task_id,
          "old_column_id" => old_column_id,
          "new_column_id" => new_column_id,
          "new_position" => new_position
        },
        socket
      ) do
    require Logger

    task_id = String.to_integer(task_id)
    old_column_id = String.to_integer(old_column_id)
    new_column_id = String.to_integer(new_column_id)

    Logger.info(
      "Move task event: task_id=#{task_id}, old_column=#{old_column_id}, new_column=#{new_column_id}, new_position=#{new_position}"
    )

    task = Tasks.get_task!(task_id)

    # If moving within the same column, just reorder
    if old_column_id == new_column_id do
      handle_task_reorder(socket, old_column_id, task_id, new_position)
    else
      handle_task_move(socket, task, new_column_id, new_position)
    end
  end

  @impl true
  def handle_event("move_column", %{"column_id" => column_id, "column_ids" => column_ids}, socket) do
    cond do
      socket.assigns.user_access != :owner ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Only the board owner can reorder columns"))}

      socket.assigns.board.ai_optimized_board ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Cannot reorder columns on AI optimized boards"))}

      true ->
        require Logger

        column_ids = Enum.map(column_ids, &String.to_integer/1)

        Logger.info("Move column event: column_id=#{column_id}, new_order=#{inspect(column_ids)}")

        Columns.reorder_columns(socket.assigns.board, column_ids)

        columns = Columns.list_columns(socket.assigns.board)

        {:noreply,
         socket
         |> push_event("move_column_success", %{})
         |> stream(:columns, columns, reset: true)
         |> load_tasks_for_columns(columns)}
    end
  end

  @impl true
  def handle_event("toggle_field", %{"field" => field_name}, socket) do
    if socket.assigns.is_owner do
      board = socket.assigns.board
      current_visibility = socket.assigns.field_visibility

      new_visibility =
        Map.put(current_visibility, field_name, !Map.get(current_visibility, field_name, false))

      case Boards.update_field_visibility(
             board,
             new_visibility,
             socket.assigns.current_scope.user
           ) do
        {:ok, updated_board} ->
          {:noreply, assign(socket, :field_visibility, updated_board.field_visibility)}

        {:error, :unauthorized} ->
          {:noreply,
           put_flash(socket, :error, gettext("Only board owners can change field visibility"))}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to update field visibility"))}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("Only board owners can change field visibility"))}
    end
  end

  @impl true
  def handle_event("create_token", params, socket) do
    user = socket.assigns.current_scope.user
    board = socket.assigns.board

    token_params = Map.merge(params["api_token"] || %{}, params["token"] || %{})

    case ApiTokens.create_api_token(user, board, token_params) do
      {:ok, {_api_token, plain_text_token}} ->
        api_tokens = ApiTokens.list_api_tokens(board)
        token_changeset = ApiTokens.change_api_token(%ApiTokens.ApiToken{}, %{})

        {:noreply,
         socket
         |> assign(:api_tokens, api_tokens)
         |> assign(:new_token, plain_text_token)
         |> assign(:token_form, to_form(token_changeset))}

      {:error, changeset} ->
        {:noreply, assign(socket, :token_form, to_form(changeset, action: :insert))}
    end
  end

  @impl true
  def handle_event("dismiss_token", _params, socket) do
    {:noreply, assign(socket, :new_token, nil)}
  end

  @impl true
  def handle_event("revoke_token", %{"id" => id}, socket) do
    api_token = ApiTokens.get_api_token!(id)
    board = socket.assigns.board

    if api_token.board_id == board.id do
      case ApiTokens.revoke_api_token(api_token) do
        {:ok, _api_token} ->
          api_tokens = ApiTokens.list_api_tokens(board)

          {:noreply,
           socket
           |> assign(:api_tokens, api_tokens)
           |> put_flash(:info, gettext("API token revoked successfully"))}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to revoke token"))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Unauthorized"))}
    end
  end

  @impl true
  def handle_info({:show_task_modal, task_id}, socket) do
    require Logger

    Logger.debug(
      "show_task_modal message: task_id=#{task_id}, current viewing_task_id=#{inspect(socket.assigns.viewing_task_id)}"
    )

    if socket.assigns.viewing_task_id == task_id do
      {:noreply, assign(socket, :show_task_modal, true)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({KanbanWeb.ColumnLive.FormComponent, {:saved, _column}}, socket) do
    columns = Columns.list_columns(socket.assigns.board)

    {:noreply,
     socket
     |> assign(:has_columns, not Enum.empty?(columns))
     |> stream(:columns, columns, reset: true)
     |> load_tasks_for_columns(columns)}
  end

  def handle_info({KanbanWeb.TaskLive.FormComponent, {:saved, _task}}, socket) do
    # Reload columns with full reset since we need to update task lists
    # This is necessary when tasks are added/edited via the modal
    columns = Columns.list_columns(socket.assigns.board)

    {:noreply,
     socket
     |> stream(:columns, columns, reset: true)
     |> load_tasks_for_columns(columns)}
  end

  @impl true
  def handle_info({Kanban.Tasks, :task_created, _task}, socket) do
    # Reload board when a task is created
    reload_board_data(socket)
  end

  @impl true
  def handle_info({Kanban.Tasks, :task_updated, _task}, socket) do
    # Reload board when a task is updated
    reload_board_data(socket)
  end

  @impl true
  def handle_info({Kanban.Tasks, :task_moved, task}, socket) do
    # Send event to JavaScript to manually update the DOM
    # This is more reliable than trying to force LiveView to update
    {:noreply,
     push_event(socket, "task_moved_remotely", %{
       task_id: task.id,
       new_column_id: task.column_id,
       new_position: task.position
     })}
  end

  @impl true
  def handle_info({Kanban.Tasks, :task_deleted, _task}, socket) do
    # Reload all tasks when a task is deleted
    # This is simpler and ensures consistency
    reload_board_data(socket)
  end

  @impl true
  def handle_info({Kanban.Tasks, :task_status_changed, _task}, socket) do
    # Reload all tasks when a task status changes
    reload_board_data(socket)
  end

  @impl true
  def handle_info({:task_updated, _task}, socket) do
    # Reload board when a task is updated via API (simple format)
    reload_board_data(socket)
  end

  @impl true
  def handle_info({:task_moved_to_review, _task}, socket) do
    # Reload board when a task is moved to Review column via API
    reload_board_data(socket)
  end

  @impl true
  def handle_info({:task_completed, _task}, socket) do
    # Reload board when a task is completed via API
    reload_board_data(socket)
  end

  @impl true
  def handle_info({Kanban.Tasks, :task_reviewed, _task}, socket) do
    # Reload board when a task review status changes
    reload_board_data(socket)
  end

  @impl true
  def handle_info({:field_visibility_updated, new_visibility}, socket) do
    {:noreply, assign(socket, :field_visibility, new_visibility)}
  end

  defp check_column_action_authorization(live_action, user_access, board)
       when live_action in [:new_column, :edit_column] do
    cond do
      user_access != :owner ->
        {:error, gettext("Only the board owner can manage columns")}

      live_action == :new_column and board.ai_optimized_board ->
        {:error, gettext("Cannot add columns to AI optimized boards")}

      live_action == :edit_column and board.ai_optimized_board ->
        {:error, gettext("Cannot edit columns on AI optimized boards")}

      true ->
        :ok
    end
  end

  defp check_column_action_authorization(_live_action, _user_access, _board), do: :ok

  defp check_new_column_authorization(:new_column, user_access, board) do
    cond do
      user_access != :owner ->
        {:error, gettext("Only the board owner can create columns")}

      board.ai_optimized_board ->
        {:error, gettext("Cannot add columns to AI optimized boards")}

      true ->
        :ok
    end
  end

  defp check_new_column_authorization(_live_action, _user_access, _board), do: :ok

  defp assign_board_state(socket, board, user_access) do
    columns = Columns.list_columns(board)

    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:board, board)
     |> assign(:user_access, user_access)
     |> assign(:can_modify, user_access in [:owner, :modify])
     |> assign(:is_owner, user_access == :owner)
     |> assign(:field_visibility, board.field_visibility || %{})
     |> assign(:has_columns, not Enum.empty?(columns))
     |> stream(:columns, columns, reset: true)
     |> load_tasks_for_columns(columns)}
  end

  defp assign_api_tokens_state(socket, board, user_access) do
    columns = Columns.list_columns(board)
    api_tokens = ApiTokens.list_api_tokens(board)
    token_changeset = ApiTokens.change_api_token(%ApiTokens.ApiToken{}, %{})

    new_token = Map.get(socket.assigns, :new_token, nil)

    {:noreply,
     socket
     |> assign(:page_title, gettext("API Tokens"))
     |> assign(:board, board)
     |> assign(:user_access, user_access)
     |> assign(:can_modify, user_access in [:owner, :modify])
     |> assign(:is_owner, user_access == :owner)
     |> assign(:field_visibility, board.field_visibility || %{})
     |> assign(:has_columns, not Enum.empty?(columns))
     |> assign(:api_tokens, api_tokens)
     |> assign(:token_form, to_form(token_changeset))
     |> assign(:new_token, new_token)
     |> assign(:viewing_task_id, nil)
     |> assign(:show_task_modal, false)
     |> stream(:columns, columns, reset: true)
     |> load_tasks_for_columns(columns)}
  end

  defp handle_task_reorder(socket, column_id, task_id, new_position) do
    column = Columns.get_column!(column_id)
    tasks = Tasks.list_tasks(column)

    # Get the current order of task IDs
    current_order = Enum.map(tasks, & &1.id)

    # Remove the task from its current position and insert it at the new position
    new_order =
      current_order
      |> List.delete(task_id)
      |> List.insert_at(new_position, task_id)

    # Persist the change to database
    Tasks.reorder_tasks(column, new_order)

    # Send success event FIRST to clear pendingMove flag, then reload tasks
    # Reset the stream so LiveView re-renders columns with updated task counts
    columns = Columns.list_columns(socket.assigns.board)

    {:noreply,
     socket
     |> push_event("move_success", %{})
     |> stream(:columns, columns, reset: true)
     |> load_tasks_for_columns(columns)}
  end

  defp handle_task_move(socket, task, new_column_id, new_position) do
    require Logger
    new_column = Columns.get_column!(new_column_id)

    Logger.info(
      "Attempting to move task #{task.id} to column #{new_column_id} at position #{new_position}"
    )

    case Tasks.move_task(task, new_column, new_position) do
      {:ok, _task} ->
        Logger.info("Task move succeeded")
        # Send success event FIRST to clear pendingMove flag, then reload tasks
        # Reset the stream so LiveView re-renders columns with updated task counts
        columns = Columns.list_columns(socket.assigns.board)

        {:noreply,
         socket
         |> push_event("move_success", %{})
         |> stream(:columns, columns, reset: true)
         |> load_tasks_for_columns(columns)}

      {:error, :wip_limit_reached} ->
        Logger.warning("Task move failed: WIP limit reached")
        # On error, we need to reload to revert the client-side change
        # Send wip_limit_violation event to trigger visual feedback on target column
        socket
        |> put_flash(:error, gettext("Cannot move task: column has reached its WIP limit"))
        |> push_event("wip_limit_violation", %{column_id: new_column_id})
        |> push_event("move_failed", %{})
        |> reload_board_columns()

      {:error, reason} ->
        Logger.error("Task move failed: #{inspect(reason)}")

        socket
        |> put_flash(:error, gettext("Failed to move task"))
        |> push_event("move_failed", %{})
        |> reload_board_columns()
    end
  end

  defp reload_board_columns(socket) do
    columns = Columns.list_columns(socket.assigns.board)

    {:noreply,
     socket
     |> stream(:columns, columns, reset: true)
     |> load_tasks_for_columns(columns)}
  end

  defp page_title(:show), do: "Show Board"
  defp page_title(:new_column), do: "New Column"
  defp page_title(:edit_column), do: "Edit Column"
  defp page_title(:new_task), do: "New Task"
  defp page_title(:api_tokens), do: "API Tokens"
  defp page_title(:edit_task), do: "Edit Task"

  defp load_tasks_for_columns(socket, columns) do
    # Load tasks for each column and store in tasks_by_column assign
    # The timestamp-based IDs in the template will force full re-renders
    tasks_by_column =
      Enum.into(columns, %{}, fn column ->
        {column.id, Tasks.list_tasks(column)}
      end)

    assign(socket, :tasks_by_column, tasks_by_column)
  end

  defp reload_board_data(socket) do
    columns = Columns.list_columns(socket.assigns.board)

    {:noreply,
     socket
     |> stream(:columns, columns, reset: true)
     |> load_tasks_for_columns(columns)}
  end

  defp subscribe_to_board_updates(socket, board_id) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{board_id}")
    end
  end

  defp assign_board_with_column(socket, board, user_access, column_id) do
    columns = Columns.list_columns(board)
    column = Columns.get_column!(column_id)

    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:board, board)
     |> assign(:user_access, user_access)
     |> assign(:can_modify, user_access in [:owner, :modify])
     |> assign(:is_owner, user_access == :owner)
     |> assign(:field_visibility, board.field_visibility || %{})
     |> assign(:column, column)
     |> assign(:column_id, column.id)
     |> assign(:has_columns, not Enum.empty?(columns))
     |> stream(:columns, columns, reset: true)
     |> load_tasks_for_columns(columns)}
  end

  @doc """
  Translates AI board column names if they match the standard keys.
  For AI optimized boards, column names are stored as English keys and translated dynamically.
  For custom boards, column names are returned as-is.
  """
  def translate_column_name(column_name) do
    case column_name do
      "Backlog" -> dgettext("boards", "Backlog")
      "Ready" -> dgettext("boards", "Ready")
      "Doing" -> dgettext("boards", "Doing")
      "Review" -> dgettext("boards", "Review")
      "Done" -> dgettext("boards", "Done")
      _ -> column_name
    end
  end
end
