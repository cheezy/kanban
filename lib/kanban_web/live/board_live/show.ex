defmodule KanbanWeb.BoardLive.Show do
  use KanbanWeb, :live_view

  alias Kanban.ApiTokens
  alias Kanban.Boards
  alias Kanban.Columns
  alias Kanban.Messages
  alias Kanban.Tasks
  alias KanbanWeb.BoardAccent
  alias KanbanWeb.BoardHeader
  alias KanbanWeb.BoardTabs
  alias KanbanWeb.ColumnEmpty
  alias KanbanWeb.ColumnHeader
  alias KanbanWeb.GoalsStrip
  alias KanbanWeb.TaskCard

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    undismissed_messages = Messages.list_undismissed_for_user(user)

    {:ok,
     socket
     |> assign(
       viewing_task_id: nil,
       show_task_modal: false,
       tasks_version: :os.system_time(:millisecond)
     )
     |> stream(:undismissed_messages, undismissed_messages)}
  end

  @impl true
  def handle_params(%{"id" => id, "column_id" => column_id, "task_id" => task_id}, _, socket) do
    with_board(socket, id, fn board, user_access ->
      resolve_column_and_task(socket, board, user_access, column_id, task_id)
    end)
  end

  def handle_params(%{"id" => id, "column_id" => column_id}, _, socket) do
    with_board(socket, id, fn board, user_access ->
      case check_column_action_authorization(socket.assigns.live_action, user_access, board) do
        :ok ->
          assign_board_with_column(socket, board, user_access, column_id)

        {:error, message} ->
          {:noreply,
           socket
           |> put_flash(:error, message)
           |> push_patch(to: ~p"/boards/#{board}")}
      end
    end)
  end

  def handle_params(%{"id" => id, "task_id" => task_id}, _, socket) do
    with_board(socket, id, fn board, user_access ->
      resolve_task_only(socket, board, user_access, task_id)
    end)
  end

  def handle_params(%{"id" => id}, _, socket) when socket.assigns.live_action == :api_tokens do
    with_board(socket, id, fn board, user_access ->
      resolve_api_tokens_view(socket, board, user_access)
    end)
  end

  def handle_params(%{"id" => id}, _, socket) do
    with_board(socket, id, fn board, user_access ->
      resolve_default_board_view(socket, board, user_access)
    end)
  end

  @impl true
  def handle_event("dismiss_message", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user
    message_id = String.to_integer(id)

    case Messages.dismiss_message(user, message_id) do
      {:ok, _} ->
        {:noreply,
         stream_delete_by_dom_id(
           socket,
           :undismissed_messages,
           "undismissed_messages-#{message_id}"
         )}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Could not dismiss message."))}
    end
  end

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
        do_delete_column(socket, id)
    end
  end

  @impl true
  def handle_event("view_task", %{"id" => id}, socket) do
    case lookup_viewable_task(socket, id) do
      {:ok, task_id} -> schedule_task_modal(socket, task_id)
      :error -> reject_view_task(socket, id)
    end
  end

  @impl true
  def handle_event("open_goal", %{"board-id" => board_id, "goal-id" => goal_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/boards/#{board_id}/goals/#{goal_id}")}
  end

  @impl true
  def handle_event("close_task_view", _, socket) do
    require Logger
    Logger.debug("close_task_view event")
    {:noreply, assign(socket, viewing_task_id: nil, show_task_modal: false)}
  end

  @impl true
  def handle_event("archive_task", %{"id" => id}, socket) do
    case authorize_modify_for_task(socket, id) do
      {:ok, task} ->
        perform_task_archive(socket, task, id)

      {:error, :not_authorized} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("You do not have permission to archive tasks on this board")
         )}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to archive task"))}
    end
  end

  @impl true
  def handle_event("delete_task", %{"id" => id}, socket) do
    case authorize_modify_for_task(socket, id) do
      {:ok, task} ->
        perform_task_delete(socket, task)

      {:error, :not_authorized} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("You do not have permission to delete tasks on this board")
         )}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to delete task"))}
    end
  end

  @impl true
  def handle_event("promote_goal_to_ready", %{"id" => id}, socket) do
    case authorize_modify_for_task(socket, id) do
      {:ok, goal} ->
        do_promote_goal(socket, goal)

      {:error, :not_authorized} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("You do not have permission to promote goals on this board")
         )}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to move goal to Ready"))}
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
    case authorize_move_task(socket, task_id, old_column_id, new_column_id) do
      {:ok, task, parsed_old_col_id, parsed_new_col_id} ->
        dispatch_authorized_move(socket, task, parsed_old_col_id, parsed_new_col_id, new_position)

      {:error, :not_authorized} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("You do not have permission to move tasks on this board")
         )}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to move task"))}
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
        do_move_column(socket, column_id, column_ids)
    end
  end

  @impl true
  def handle_event("toggle_field", %{"field" => field_name}, socket) do
    cond do
      not socket.assigns.is_owner ->
        {:noreply,
         put_flash(socket, :error, gettext("Only board owners can change field visibility"))}

      field_name not in Boards.Board.toggleable_fields() ->
        # W401: reject any client-supplied "field" name that is not on the
        # canonical allow-list before it lands in the JSONB map.
        {:noreply, put_flash(socket, :error, gettext("Invalid field name"))}

      true ->
        do_toggle_field(socket, field_name)
    end
  end

  @impl true
  def handle_event("create_token", params, socket) do
    if socket.assigns.can_modify do
      do_create_token(socket, params)
    else
      {:noreply,
       put_flash(socket, :error, gettext("You do not have permission to manage API tokens"))}
    end
  end

  @impl true
  def handle_event("dismiss_token", _params, socket) do
    {:noreply, assign(socket, :new_token, nil)}
  end

  @impl true
  def handle_event("revoke_token", %{"id" => id}, socket) do
    if socket.assigns.can_modify do
      do_revoke_token(socket, id)
    else
      {:noreply,
       put_flash(socket, :error, gettext("You do not have permission to manage API tokens"))}
    end
  end

  def handle_event("delete_token", %{"id" => id}, socket) do
    if socket.assigns.can_modify do
      do_delete_token(socket, id)
    else
      {:noreply,
       put_flash(socket, :error, gettext("You do not have permission to manage API tokens"))}
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
    Process.send_after(self(), :clear_skip_reload, 100)
    {:noreply, assign(socket, :skip_next_reload, true)}
  end

  def handle_info({KanbanWeb.BoardLive.SettingsFormComponent, {:saved, board}}, socket) do
    user = socket.assigns.current_scope.user
    {:noreply, assign(socket, :board, put_board_metrics(board, user))}
  end

  def handle_info(
        {KanbanWeb.BoardLive.SettingsFormComponent, {:field_visibility_updated, vis}},
        socket
      ) do
    {:noreply, assign(socket, :field_visibility, vis)}
  end

  @impl true
  def handle_info({Kanban.Tasks, :task_created, _task}, socket) do
    # Reload board when a task is created
    reload_board_data(socket)
  end

  @impl true
  def handle_info({Kanban.Tasks, :task_updated, _task}, socket) do
    if socket.assigns[:skip_next_reload],
      do: {:noreply, socket},
      else: reload_board_data(socket)
  end

  @impl true
  def handle_info({Kanban.Tasks, :task_moved, task}, socket) do
    # Send event to JavaScript to manually update the DOM
    # This is more reliable than trying to force LiveView to update.
    # Also refresh per-board metrics (BoardHeader KV counts) and
    # reload the column tasks so the GoalsStrip flow segments
    # recompute after a remote move from another client.
    columns = Columns.list_columns(socket.assigns.board)

    {:noreply,
     socket
     |> push_event("task_moved_remotely", %{
       task_id: task.id,
       new_column_id: task.column_id,
       new_position: task.position
     })
     |> load_tasks_for_columns(columns)
     |> refresh_board_metrics()}
  end

  @impl true
  def handle_info({Kanban.Tasks, :task_deleted, _task}, socket) do
    if socket.assigns[:skip_next_reload],
      do: {:noreply, socket},
      else: reload_board_data(socket)
  end

  @impl true
  def handle_info({Kanban.Tasks, :task_status_changed, _task}, socket) do
    if socket.assigns[:skip_next_reload],
      do: {:noreply, socket},
      else: reload_board_data(socket)
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
    if socket.assigns[:skip_next_reload],
      do: {:noreply, socket},
      else: reload_board_data(socket)
  end

  @impl true
  def handle_info({:field_visibility_updated, new_visibility}, socket) do
    {:noreply, assign(socket, :field_visibility, new_visibility)}
  end

  @impl true
  def handle_info(:clear_skip_reload, socket) do
    {:noreply, assign(socket, :skip_next_reload, false)}
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

  defp authorize_modify_for_task(socket, raw_id) do
    if socket.assigns.can_modify do
      lookup_task_for_board(socket, raw_id)
    else
      {:error, :not_authorized}
    end
  end

  defp lookup_task_for_board(socket, raw_id) do
    with {:ok, id} <- parse_task_id(raw_id),
         %{} = task <- Tasks.get_task_for_board(id, socket.assigns.board.id) do
      {:ok, task}
    else
      _ -> {:error, :not_found}
    end
  end

  defp parse_task_id(id) when is_integer(id), do: {:ok, id}

  defp parse_task_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_task_id(_), do: :error

  defp do_promote_goal(socket, goal) do
    case Tasks.promote_goal_to_ready(goal, socket.assigns.board.id) do
      {:ok, count} ->
        columns = Columns.list_columns(socket.assigns.board)

        {:noreply,
         socket
         |> put_flash(
           :info,
           dngettext(
             "tasks",
             "Moved 1 task to Ready",
             "Moved %{count} tasks to Ready",
             count,
             count: count
           )
         )
         |> stream(:columns, columns, reset: true)
         |> load_tasks_for_columns(columns)}

      {:error, :not_a_goal} ->
        {:noreply, put_flash(socket, :error, gettext("Only goals can be promoted"))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to move goal to Ready"))}
    end
  end

  defp do_create_token(socket, params) do
    user = socket.assigns.current_scope.user
    board = socket.assigns.board
    token_params = build_token_params(params)

    case ApiTokens.create_api_token(user, board, token_params) do
      {:ok, {_api_token, plain_text_token}} ->
        assign_created_token(socket, board, plain_text_token)

      {:error, changeset} ->
        {:noreply, assign(socket, :token_form, to_form(changeset, action: :insert))}
    end
  end

  defp build_token_params(params) do
    params["api_token"]
    |> Map.merge(params["token"] || %{})
    |> parse_agent_capabilities()
  end

  defp assign_created_token(socket, board, plain_text_token) do
    api_tokens = ApiTokens.list_api_tokens(board)
    token_changeset = ApiTokens.change_api_token(%ApiTokens.ApiToken{}, %{})

    {:noreply,
     socket
     |> assign(:api_tokens, api_tokens)
     |> assign(:new_token, plain_text_token)
     |> assign(:token_form, to_form(token_changeset))}
  end

  defp do_revoke_token(socket, id) do
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

  defp do_delete_token(socket, id) do
    api_token = ApiTokens.get_api_token!(id)
    board = socket.assigns.board

    if api_token.board_id == board.id do
      case ApiTokens.delete_api_token(api_token) do
        {:ok, _api_token} ->
          api_tokens = ApiTokens.list_api_tokens(board)

          {:noreply,
           socket
           |> assign(:api_tokens, api_tokens)
           |> put_flash(:info, gettext("API token deleted successfully"))}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to delete token"))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Unauthorized"))}
    end
  end

  defp dispatch_authorized_move(socket, task, old_col_id, new_col_id, new_position) do
    require Logger

    Logger.info(
      "Move task event: task_id=#{task.id}, old_column=#{old_col_id}, new_column=#{new_col_id}, new_position=#{new_position}"
    )

    if old_col_id == new_col_id do
      handle_task_reorder(socket, old_col_id, task.id, new_position)
    else
      handle_task_move(socket, task, new_col_id, new_position)
    end
  end

  defp authorize_move_task(socket, raw_task_id, raw_old_col_id, raw_new_col_id) do
    if socket.assigns.can_modify do
      lookup_move_targets(socket, raw_task_id, raw_old_col_id, raw_new_col_id)
    else
      {:error, :not_authorized}
    end
  end

  defp lookup_move_targets(socket, raw_task_id, raw_old_col_id, raw_new_col_id) do
    board_id = socket.assigns.board.id

    with {:ok, ids} <- parse_move_ids(raw_task_id, raw_old_col_id, raw_new_col_id),
         {:ok, task} <- fetch_move_targets(board_id, ids) do
      {task_id, old_col_id, new_col_id} = ids
      _ = task_id
      {:ok, task, old_col_id, new_col_id}
    else
      _ -> {:error, :not_found}
    end
  end

  defp parse_move_ids(raw_task_id, raw_old_col_id, raw_new_col_id) do
    with {:ok, task_id} <- parse_task_id(raw_task_id),
         {:ok, old_col_id} <- parse_task_id(raw_old_col_id),
         {:ok, new_col_id} <- parse_task_id(raw_new_col_id) do
      {:ok, {task_id, old_col_id, new_col_id}}
    end
  end

  defp fetch_move_targets(board_id, {task_id, old_col_id, new_col_id}) do
    with %{} = task <- Tasks.get_task_for_board(task_id, board_id),
         %{} <- Columns.get_column_for_board(old_col_id, board_id),
         %{} <- Columns.get_column_for_board(new_col_id, board_id) do
      {:ok, task}
    else
      _ -> :error
    end
  end

  defp assign_common_board_state(socket, board, user_access, columns) do
    user = socket.assigns.current_scope.user
    board_with_metrics = put_board_metrics(board, user)

    socket
    |> assign(:page_title, page_title(socket.assigns.live_action))
    |> assign(:board, board_with_metrics)
    |> assign(:user_access, user_access)
    |> assign(:can_modify, user_access in [:owner, :modify])
    |> assign(:is_owner, user_access == :owner)
    |> assign(:field_visibility, board.field_visibility || %{})
    |> assign(:has_columns, not Enum.empty?(columns))
    |> stream(:columns, columns, reset: true)
    |> load_tasks_for_columns(columns)
  end

  # Attach the per-board metrics map AND the members list to the board
  # struct so the BoardHeader sub-band can render the in-flight/in-
  # review/shipped counts plus an avatar stack of everyone on the
  # board to the right of the stats. Falls back to an empty metrics
  # map (zeros) and an empty member list when the user can't read
  # them, which BoardHeader handles via Map.get fallbacks.
  defp put_board_metrics(board, user) do
    board =
      case Boards.get_board_metrics(user, board.id) do
        {:ok, metrics} -> %{board | metrics: metrics}
        {:error, _} -> board
      end

    board = %{board | members: Boards.list_board_members(board.id)}
    Map.put(board, :accent, BoardAccent.for_board(board, user))
  end

  defp assign_board_state(socket, board, user_access) do
    columns = Columns.list_columns(board)

    {:noreply, assign_common_board_state(socket, board, user_access, columns)}
  end

  defp assign_api_tokens_state(socket, board, user_access) do
    columns = Columns.list_columns(board)
    api_tokens = ApiTokens.list_api_tokens(board)
    token_changeset = ApiTokens.change_api_token(%ApiTokens.ApiToken{}, %{})

    new_token = Map.get(socket.assigns, :new_token, nil)

    {:noreply,
     socket
     |> assign_common_board_state(board, user_access, columns)
     |> assign(:page_title, "Stride")
     |> assign(:api_tokens, api_tokens)
     |> assign(:token_form, to_form(token_changeset))
     |> assign(:new_token, new_token)
     |> assign(:viewing_task_id, nil)
     |> assign(:show_task_modal, false)}
  end

  defp handle_task_reorder(socket, column_id, task_id, new_position) do
    # IDs here were already board-scoped by authorize_move_task; the scoped
    # lookup is defense-in-depth in case this helper is ever called directly.
    case Columns.get_column_for_board(column_id, socket.assigns.board.id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Column not found on this board"))}

      column ->
        do_handle_task_reorder(socket, column, task_id, new_position)
    end
  end

  defp do_handle_task_reorder(socket, column, task_id, new_position) do
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

    case Columns.get_column_for_board(new_column_id, socket.assigns.board.id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Column not found on this board"))}

      new_column ->
        Logger.info(
          "Attempting to move task #{task.id} to column #{new_column_id} at position #{new_position}"
        )

        do_handle_task_move(socket, task, new_column, new_position)
    end
  end

  defp do_handle_task_move(socket, task, new_column, new_position) do
    require Logger

    case Tasks.move_task(task, new_column, new_position) do
      {:ok, _task} ->
        handle_task_move_success(socket)

      {:error, :wip_limit_reached} ->
        handle_task_move_wip_limit(socket, new_column)

      {:error, reason} ->
        Logger.error("Task move failed: #{inspect(reason)}")

        socket
        |> put_flash(:error, gettext("Failed to move task"))
        |> push_event("move_failed", %{})
        |> reload_board_columns()
    end
  end

  defp handle_task_move_success(socket) do
    require Logger
    Logger.info("Task move succeeded")
    # Send success event FIRST to clear pendingMove flag, then reload tasks
    # Reset the stream so LiveView re-renders columns with updated task counts
    columns = Columns.list_columns(socket.assigns.board)

    {:noreply,
     socket
     |> push_event("move_success", %{})
     |> stream(:columns, columns, reset: true)
     |> load_tasks_for_columns(columns)
     |> refresh_board_metrics()}
  end

  defp handle_task_move_wip_limit(socket, new_column) do
    require Logger
    Logger.warning("Task move failed: WIP limit reached")
    # On error, we need to reload to revert the client-side change
    # Send wip_limit_violation event to trigger visual feedback on target column
    socket
    |> put_flash(:error, gettext("Cannot move task: column has reached its WIP limit"))
    |> push_event("wip_limit_violation", %{column_id: new_column.id})
    |> push_event("move_failed", %{})
    |> reload_board_columns()
  end

  defp reload_board_columns(socket) do
    columns = Columns.list_columns(socket.assigns.board)

    {:noreply,
     socket
     |> stream(:columns, columns, reset: true)
     |> load_tasks_for_columns(columns)
     |> refresh_board_metrics()}
  end

  defp page_title(:show), do: "Stride"
  defp page_title(:new_column), do: "New Column"
  defp page_title(:edit_column), do: "Edit Column"
  defp page_title(:new_task), do: "Stride"
  defp page_title(:api_tokens), do: "Stride"
  defp page_title(:edit_task), do: "Edit Task"
  defp page_title(:edit_task_in_column), do: "Edit Task"
  defp page_title(:manage_members), do: "Manage Members"
  defp page_title(:board_settings), do: "Board Settings"

  defp load_tasks_for_columns(socket, columns) do
    grouped = Tasks.list_tasks_by_columns(columns)

    tasks_by_column =
      Enum.into(columns, %{}, fn column ->
        tasks = Map.get(grouped, column.id, [])

        tasks =
          if column.name == "Done",
            do: Tasks.sort_by_goal_hierarchy(tasks),
            else: tasks

        {column.id, tasks}
      end)

    goal_progress = compute_goal_progress(tasks_by_column, socket.assigns.board.id)
    backlog_goals_with_children = compute_backlog_promotable_goals(columns, tasks_by_column)
    goals_by_id = compute_goals_by_id(tasks_by_column)

    goals =
      compute_active_goals(tasks_by_column, columns, goals_by_id, backlog_goals_with_children)

    socket
    |> assign(:tasks_by_column, tasks_by_column)
    |> assign(:goal_progress, goal_progress)
    |> assign(:backlog_goals_with_children, backlog_goals_with_children)
    |> assign(:goals_by_id, goals_by_id)
    |> assign(:goals, goals)
    |> assign(:tasks_version, :os.system_time(:millisecond))
  end

  # Build the list of active goals shaped for KanbanWeb.GoalsStrip.
  # Each entry has :identifier, :name, :color, :ink, :promoted plus a
  # :flow map of segmented child-task counts per status. The list is
  # sorted by identifier so the strip's order is stable across refreshes.
  defp compute_active_goals(tasks_by_column, columns, goals_by_id, backlog_promotable) do
    status_by_column_id = Map.new(columns, fn col -> {col.id, column_status(col.name)} end)

    goals_by_id
    |> Enum.map(&build_active_goal(&1, tasks_by_column, status_by_column_id, backlog_promotable))
    |> Enum.sort_by(& &1.identifier)
  end

  defp build_active_goal({goal_id, info}, tasks_by_column, status_by_column_id, promotable) do
    info
    |> Map.put(:name, info.short)
    |> Map.put(:flow, goal_flow_for(goal_id, tasks_by_column, status_by_column_id))
    |> Map.put(:promoted, not MapSet.member?(promotable, goal_id))
  end

  # Sums up child-task counts per status bucket for one goal, plus the
  # total. Children are tasks whose parent_id == goal_id; their column's
  # status atom (via column_status/1) drives which bucket they land in.
  defp goal_flow_for(goal_id, tasks_by_column, status_by_column_id) do
    empty = %{done: 0, review: 0, doing: 0, ready: 0, backlog: 0, total: 0}

    Enum.reduce(tasks_by_column, empty, fn {column_id, tasks}, acc ->
      status = Map.get(status_by_column_id, column_id, :backlog)
      n = Enum.count(tasks, fn task -> task.parent_id == goal_id end)

      if n > 0 do
        acc
        |> Map.update!(status, &(&1 + n))
        |> Map.update!(:total, &(&1 + n))
      else
        acc
      end
    end)
  end

  # Build a lookup map keyed by goal task id, value being the small
  # chip-shaped map TaskCard's goal_chip reads: identifier, short name,
  # and a deterministic accent color/ink derived from the goal id.
  defp compute_goals_by_id(tasks_by_column) do
    tasks_by_column
    |> Map.values()
    |> List.flatten()
    |> Enum.filter(&(&1.type == :goal))
    |> Map.new(fn goal ->
      {goal.id,
       %{
         id: goal.id,
         identifier: goal.identifier,
         short: goal.title,
         color: goal_accent_color(goal.id),
         ink: goal_accent_ink(goal.id)
       }}
    end)
  end

  @goal_accents [
    {"var(--stride-orange)", "var(--stride-orange-ink)"},
    {"var(--st-ready)", "var(--st-ready)"},
    {"var(--st-doing)", "var(--st-doing)"},
    {"var(--stride-violet)", "var(--stride-violet-ink)"},
    {"var(--st-done)", "var(--st-done)"},
    {"var(--st-review)", "var(--st-review)"}
  ]

  defp goal_accent_color(id) when is_integer(id) do
    {color, _ink} = Enum.at(@goal_accents, rem(id, length(@goal_accents)))
    color
  end

  defp goal_accent_color(_), do: "var(--stride-violet)"

  defp goal_accent_ink(id) when is_integer(id) do
    {_color, ink} = Enum.at(@goal_accents, rem(id, length(@goal_accents)))
    ink
  end

  defp goal_accent_ink(_), do: "var(--stride-violet-ink)"

  defp compute_goal_progress(tasks_by_column, board_id) do
    tasks_by_column
    |> Enum.flat_map(fn {_column_id, tasks} -> tasks end)
    |> Enum.filter(&(&1.type == :goal))
    |> Enum.into(%{}, fn goal ->
      children = Tasks.get_task_children(goal.id, board_id)
      total = length(children)
      completed = Enum.count(children, &(&1.status == :completed))
      percentage = if total > 0, do: round(completed / total * 100), else: 0
      {goal.id, %{total: total, completed: completed, percentage: percentage}}
    end)
  end

  defp compute_backlog_promotable_goals(columns, tasks_by_column) do
    case Enum.find(columns, fn col -> col.name == "Backlog" end) do
      nil -> MapSet.new()
      backlog_col -> promotable_goal_ids(Map.get(tasks_by_column, backlog_col.id, []))
    end
  end

  defp promotable_goal_ids(backlog_tasks) do
    backlog_child_parent_ids = backlog_child_parent_ids(backlog_tasks)

    backlog_tasks
    |> Enum.filter(fn t ->
      t.type == :goal and MapSet.member?(backlog_child_parent_ids, t.id)
    end)
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  defp backlog_child_parent_ids(backlog_tasks) do
    backlog_tasks
    |> Enum.reject(&is_nil(&1.parent_id))
    |> Enum.map(& &1.parent_id)
    |> MapSet.new()
  end

  defp reload_board_data(socket) do
    columns = Columns.list_columns(socket.assigns.board)

    {:noreply,
     socket
     |> stream(:columns, columns)
     |> load_tasks_for_columns(columns)
     |> refresh_board_metrics()}
  end

  # Re-reads the metrics for the currently-loaded board and reassigns
  # `:board` so the BoardHeader KV counts stay in sync after every
  # task move / create / delete / status change.
  defp refresh_board_metrics(socket) do
    user = socket.assigns.current_scope.user
    board = put_board_metrics(socket.assigns.board, user)
    assign(socket, :board, board)
  end

  defp refresh_board_tasks(socket, board) do
    columns = Columns.list_columns(board)

    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:viewing_task_id, nil)
     |> assign(:show_task_modal, false)
     |> load_tasks_for_columns(columns)}
  end

  defp subscribe_to_board_updates(socket, board_id) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{board_id}")
    end
  end

  defp parse_agent_capabilities(params) do
    case params do
      %{"agent_capabilities" => capabilities} when is_binary(capabilities) ->
        parsed_capabilities =
          capabilities
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()

        Map.put(params, "agent_capabilities", parsed_capabilities)

      _ ->
        params
    end
  end

  defp assign_board_with_column(socket, board, user_access, column_id) do
    with {:ok, column_id_int} <- parse_task_id(column_id),
         %Columns.Column{} = column <- Columns.get_column_for_board(column_id_int, board.id) do
      columns = Columns.list_columns(board)

      {:noreply,
       socket
       |> assign_common_board_state(board, user_access, columns)
       |> assign(:column, column)
       |> assign(:column_id, column.id)}
    else
      _ ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Column not found on this board"))
         |> push_patch(to: ~p"/boards/#{board}")}
    end
  end

  defp assign_column_and_task(socket, board, user_access, column, task) do
    columns = Columns.list_columns(board)
    task = Kanban.Repo.preload(task, :assigned_to)

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

  defp assign_task_only(socket, board, user_access, task) do
    columns = Columns.list_columns(board)
    task = Kanban.Repo.preload(task, :assigned_to)

    socket =
      socket
      |> assign_task_only_base(board, user_access, task, columns)
      |> stream(:columns, columns, reset: true)
      |> maybe_load_tasks(columns)

    {:noreply, socket}
  end

  defp assign_task_only_base(socket, board, user_access, task, columns) do
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
  end

  defp maybe_load_tasks(socket, columns) do
    if Map.has_key?(socket.assigns, :tasks_by_column) do
      socket
    else
      load_tasks_for_columns(socket, columns)
    end
  end

  defp do_delete_column(socket, raw_id) do
    with {:ok, column_id} <- parse_task_id(raw_id),
         %Columns.Column{} = column <-
           Columns.get_column_for_board(column_id, socket.assigns.board.id) do
      perform_column_deletion(socket, column)
    else
      _ ->
        {:noreply, put_flash(socket, :error, gettext("Column not found on this board"))}
    end
  end

  defp do_toggle_field(socket, field_name) do
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
  end

  defp perform_column_deletion(socket, column) do
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

  defp resolve_column_and_task(socket, board, user_access, column_id, task_id) do
    case fetch_column_and_task(board, column_id, task_id) do
      {:ok, column, task} ->
        assign_column_and_task(socket, board, user_access, column, task)

      :error ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Column or task not found on this board"))
         |> push_patch(to: ~p"/boards/#{board}")}
    end
  end

  defp fetch_column_and_task(board, column_id, task_id) do
    with {:ok, column_id_int} <- parse_task_id(column_id),
         {:ok, task_id_int} <- parse_task_id(task_id),
         %Columns.Column{} = column <- Columns.get_column_for_board(column_id_int, board.id),
         %Tasks.Task{} = task <- Tasks.get_task_for_board(task_id_int, board.id) do
      {:ok, column, task}
    else
      _ -> :error
    end
  end

  defp resolve_task_only(socket, board, user_access, task_id) do
    with {:ok, task_id_int} <- parse_task_id(task_id),
         %Tasks.Task{} = task <- Tasks.get_task_for_board(task_id_int, board.id) do
      assign_task_only(socket, board, user_access, task)
    else
      _ ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Task not found on this board"))
         |> push_patch(to: ~p"/boards/#{board}")}
    end
  end

  defp resolve_api_tokens_view(socket, board, user_access) do
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

  defp resolve_default_board_view(socket, board, user_access) do
    case check_new_column_authorization(socket.assigns.live_action, user_access, board) do
      :ok ->
        if same_board_show?(socket, board) do
          refresh_board_tasks(socket, board)
        else
          assign_board_state(socket, board, user_access)
        end

      {:error, message} ->
        {:noreply,
         socket
         |> put_flash(:error, message)
         |> push_patch(to: ~p"/boards/#{board}")}
    end
  end

  defp same_board_show?(socket, board) do
    socket.assigns.live_action == :show and
      Map.get(socket.assigns, :board) != nil and
      socket.assigns.board.id == board.id
  end

  defp lookup_viewable_task(socket, id) do
    with {:ok, task_id} <- parse_task_id(id),
         %{} <- Tasks.get_task_for_board(task_id, socket.assigns.board.id) do
      {:ok, task_id}
    else
      _ -> :error
    end
  end

  defp schedule_task_modal(socket, task_id) do
    require Logger
    Logger.debug("view_task event: task_id=#{task_id}, scheduling modal show")
    Process.send_after(self(), {:show_task_modal, task_id}, 100)
    {:noreply, assign(socket, viewing_task_id: task_id, show_task_modal: false)}
  end

  defp reject_view_task(socket, id) do
    require Logger
    Logger.debug("view_task event: rejected client-supplied id=#{inspect(id)}")
    {:noreply, put_flash(socket, :error, gettext("Task not found"))}
  end

  defp perform_task_archive(socket, task, id) do
    require Logger

    case Tasks.archive_task(task) do
      {:ok, _archived_task} ->
        columns = Columns.list_columns(socket.assigns.board)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Task archived successfully"))
         |> stream(:columns, columns, reset: true)
         |> load_tasks_for_columns(columns)}

      {:error, changeset} ->
        Logger.error("Failed to archive task #{id}: #{inspect(changeset.errors)}")
        {:noreply, put_flash(socket, :error, gettext("Failed to archive task"))}
    end
  end

  defp perform_task_delete(socket, task) do
    case Tasks.delete_task(task) do
      {:ok, _deleted_task} ->
        columns = Columns.list_columns(socket.assigns.board)

        Process.send_after(self(), :clear_skip_reload, 100)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Task deleted successfully"))
         |> assign(:skip_next_reload, true)
         |> stream(:columns, columns)
         |> load_tasks_for_columns(columns)}

      {:error, :has_dependents} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Cannot delete task: other tasks depend on it. Remove dependencies first.")
         )}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to delete task"))}
    end
  end

  defp do_move_column(socket, column_id, column_ids) do
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

  defp with_board(socket, id, fun) do
    user = socket.assigns.current_scope.user

    case Boards.get_board(id, user) do
      {:ok, board} ->
        user_access = Boards.get_user_access(board.id, user.id)
        subscribe_to_board_updates(socket, board.id)
        fun.(board, user_access)

      {:error, :not_found} ->
        handle_board_not_found(socket)
    end
  end

  defp handle_board_not_found(socket) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("Board not found"))
     |> push_navigate(to: ~p"/boards")}
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

  @doc """
  Maps a column name to a canonical status atom for the per-column
  status-colored chrome (status dot color, empty-state hint copy).
  Falls back to `:backlog` for custom column names on non-AI-optimized
  boards.
  """
  def column_status(name) when is_binary(name) do
    case String.downcase(name) do
      "backlog" -> :backlog
      "ready" -> :ready
      "doing" -> :doing
      "review" -> :review
      "done" -> :done
      _ -> :backlog
    end
  end

  def column_status(_), do: :backlog

  @doc """
  Adapts a `%Kanban.Tasks.Task{}` into the duck-typed map shape the
  `KanbanWeb.TaskCard` component expects. Adds `:claimed_by` /
  `:completed_by` avatar maps when the task has the relevant fields
  populated, and `:promoted` so `KanbanWeb.GoalCard` knows whether to
  show the "Promote children to Ready" affordance.
  """
  def task_card_data(
        task,
        backlog_goals_with_children \\ MapSet.new(),
        goal_progress \\ %{},
        goals_by_id \\ %{}
      ) do
    task
    |> Map.from_struct()
    |> Map.merge(task_card_avatars(task))
    |> Map.merge(
      task_card_goal_fields(task, backlog_goals_with_children, goal_progress, goals_by_id)
    )
    |> Map.merge(task_card_meta_counts(task))
    |> Map.merge(task_card_review_fields(task))
    |> Map.merge(task_card_done_fields(task))
  end

  defp task_card_avatars(task) do
    %{claimed_by: claimed_by_for(task), completed_by: completed_by_for(task)}
  end

  defp task_card_goal_fields(task, backlog_goals_with_children, goal_progress, goals_by_id) do
    %{
      promoted: not MapSet.member?(backlog_goals_with_children, task.id),
      children: children_for(task, goal_progress),
      goal: Map.get(goals_by_id, task.parent_id)
    }
  end

  defp task_card_meta_counts(task) do
    %{
      key_files_count: count_or_nil(Map.get(task, :key_files)),
      deps_count: count_or_nil(Map.get(task, :dependencies)),
      acceptance_count: acceptance_count(Map.get(task, :acceptance_criteria))
    }
  end

  # Reviewer fields surface the task-reviewer subagent's verdict on the
  # task — populated at completion time. JSONB storage means the map
  # comes back with string keys; we look them up explicitly.
  defp task_card_review_fields(task) do
    reviewer = Map.get(task, :reviewer_result) || %{}

    %{
      reviewer_skipped?: reviewer_skipped?(reviewer),
      reviewer_skip_reason: get_in_either(reviewer, [:reason, "reason"]),
      criteria_checked:
        get_in_either(reviewer, [:acceptance_criteria_checked, "acceptance_criteria_checked"]),
      issues_found: get_in_either(reviewer, [:issues_found, "issues_found"]),
      files_changed_count: count_files_changed(Map.get(task, :actual_files_changed))
    }
  end

  defp task_card_done_fields(task) do
    %{cycle_time: cycle_time_for(task)}
  end

  defp reviewer_skipped?(reviewer) when is_map(reviewer) do
    case get_in_either(reviewer, [:dispatched, "dispatched"]) do
      false -> true
      _ -> false
    end
  end

  defp reviewer_skipped?(_), do: false

  defp get_in_either(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn k -> Map.get(map, k) end)
  end

  defp get_in_either(_, _), do: nil

  defp count_files_changed(str) when is_binary(str) do
    case str
         |> String.split(",", trim: true)
         |> Enum.map(&String.trim/1)
         |> Enum.reject(&(&1 == ""))
         |> length() do
      0 -> nil
      n -> n
    end
  end

  defp count_files_changed(_), do: nil

  # Formats cycle time as "Nh Mm", "Nm", or "Ns" depending on duration.
  # Returns nil when the task hasn't been both claimed and completed.
  defp cycle_time_for(%{claimed_at: %DateTime{} = claimed, completed_at: %DateTime{} = completed}) do
    format_duration(DateTime.diff(completed, claimed, :second))
  end

  defp cycle_time_for(_), do: nil

  # Cycle time is always rendered in hours and minutes. Hours appear
  # only when the duration is ≥ 60 minutes; sub-hour durations show
  # just minutes. Multi-day cycles roll up into hours (a 30-hour cycle
  # reads "30h 15m", not "1d 6h") to keep the unit consistent.
  defp format_duration(secs) when is_integer(secs) and secs >= 0 do
    total_mins = div(secs, 60)
    hours = div(total_mins, 60)
    mins = rem(total_mins, 60)

    cond do
      hours == 0 -> "#{mins}m"
      mins == 0 -> "#{hours}h"
      true -> "#{hours}h #{mins}m"
    end
  end

  defp format_duration(_), do: nil

  # Returns the length of a non-empty list, or nil for empty/non-list
  # so TaskCard.backlog_meta hides the chip entirely when there's
  # nothing to surface.
  defp count_or_nil(list) when is_list(list) do
    case length(list) do
      0 -> nil
      n -> n
    end
  end

  defp count_or_nil(_), do: nil

  defp acceptance_count(text) when is_binary(text) do
    case text
         |> String.split("\n", trim: true)
         |> Enum.reject(&(String.trim(&1) == ""))
         |> length() do
      0 -> nil
      n -> n
    end
  end

  defp acceptance_count(_), do: nil

  defp children_for(%{type: :goal, id: id}, goal_progress) do
    case Map.get(goal_progress, id) do
      %{total: total, completed: done} when is_integer(total) ->
        %{total: total, done: done, review: 0, doing: 0, ready: 0}

      _ ->
        nil
    end
  end

  defp children_for(_task, _goal_progress), do: nil

  # Build the top-right avatar from `assigned_to` whenever a user is
  # assigned to the task — covers both "assigned but not yet claimed"
  # and "claimed and in progress." The legacy template surfaced an
  # assigned-user icon for both states; the new card uses the avatar
  # in the same slot.
  defp claimed_by_for(%{assigned_to: %{id: _id} = user}) do
    %{kind: :human, name: user_display_name(user), palette: human_palette(user.id)}
  end

  defp claimed_by_for(_), do: nil

  defp completed_by_for(%{completed_by_agent: nil}), do: nil

  defp completed_by_for(%{completed_by_agent: agent}) when is_binary(agent) do
    %{kind: :agent, name: agent, palette: agent_palette(agent)}
  end

  defp completed_by_for(_), do: nil

  defp user_display_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp user_display_name(%{email: email}) when is_binary(email), do: email
  defp user_display_name(_), do: "?"

  @human_palettes ~w(human-blue human-amber human-green human-pink)
  defp human_palette(user_id) when is_integer(user_id) do
    Enum.at(@human_palettes, rem(user_id, length(@human_palettes)))
  end

  defp human_palette(_), do: "human-blue"

  defp agent_palette(name) when is_binary(name) do
    case name |> String.downcase() |> String.split() |> List.first() do
      "claude" -> "agent-claude"
      "cursor" -> "agent-cursor"
      "aider" -> "agent-aider"
      "codex" -> "agent-codex"
      _ -> "agent-claude"
    end
  end

  defp agent_palette(_), do: "agent-claude"
end
