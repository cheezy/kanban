defmodule KanbanWeb.BoardLive.Show do
  use KanbanWeb, :live_view

  alias Kanban.Boards
  alias Kanban.Columns
  alias Kanban.Messages
  alias Kanban.Tasks.BoardFilters
  alias KanbanWeb.BoardFilterBar
  alias KanbanWeb.BoardHeader
  alias KanbanWeb.BoardLive.ApiTokens
  alias KanbanWeb.BoardLive.Authorization
  alias KanbanWeb.BoardLive.BoardState
  alias KanbanWeb.BoardLive.ColumnActions
  alias KanbanWeb.BoardLive.FilterActions
  alias KanbanWeb.BoardLive.Params
  alias KanbanWeb.BoardLive.TaskActions
  alias KanbanWeb.BoardLive.TaskCardData
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
       column_id: nil,
       tasks_version: :os.system_time(:millisecond),
       board_filters: %BoardFilters{},
       filter_options: FilterActions.empty_options(),
       filters_active: false,
       visible_tasks_by_column: %{}
     )
     |> stream(:undismissed_messages, undismissed_messages)}
  end

  @impl true
  def handle_params(%{"id" => id, "column_id" => column_id, "task_id" => task_id}, _, socket) do
    Params.with_board(socket, id, fn board, user_access ->
      Params.resolve_column_and_task(socket, board, user_access, column_id, task_id)
    end)
  end

  def handle_params(%{"id" => id, "column_id" => column_id}, _, socket) do
    Params.with_board(socket, id, fn board, user_access ->
      Params.resolve_column_action(socket, board, user_access, column_id)
    end)
  end

  def handle_params(%{"id" => id, "task_id" => task_id}, _, socket) do
    Params.with_board(socket, id, fn board, user_access ->
      Params.resolve_task_only(socket, board, user_access, task_id)
    end)
  end

  def handle_params(%{"id" => id}, _, socket) when socket.assigns.live_action == :api_tokens do
    Params.with_board(socket, id, fn board, user_access ->
      ApiTokens.resolve_api_tokens_view(socket, board, user_access)
    end)
  end

  def handle_params(%{"id" => id}, _, socket) when socket.assigns.live_action == :new_goal do
    Params.with_board(socket, id, fn board, user_access ->
      Params.resolve_new_goal(socket, board, user_access)
    end)
  end

  def handle_params(%{"id" => id} = params, _, socket) do
    Params.with_board(socket, id, fn board, user_access ->
      Params.resolve_default_board_view(socket, board, user_access, params)
    end)
  end

  @impl true
  def handle_event("filter_change", params, socket),
    do: FilterActions.handle_filter_change(socket, params)

  def handle_event("clear_filters", _params, socket), do: FilterActions.clear_filters(socket)

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
        ColumnActions.do_delete_column(socket, id)
    end
  end

  @impl true
  def handle_event("view_task", %{"id" => id}, socket) do
    case TaskActions.lookup_viewable_task(socket, id) do
      {:ok, %{id: task_id, type: :goal}} ->
        {:noreply,
         push_navigate(socket, to: ~p"/boards/#{socket.assigns.board}/goals/#{task_id}")}

      {:ok, %{id: task_id}} ->
        TaskActions.schedule_task_modal(socket, task_id)

      :error ->
        TaskActions.reject_view_task(socket, id)
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
    case Authorization.authorize_modify_for_task(socket, id) do
      {:ok, task} ->
        TaskActions.perform_task_archive(socket, task, id)

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
    case Authorization.authorize_modify_for_task(socket, id) do
      {:ok, task} ->
        TaskActions.perform_task_delete(socket, task)

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
    case Authorization.authorize_modify_for_task(socket, id) do
      {:ok, goal} ->
        TaskActions.do_promote_goal(socket, goal)

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
  def handle_event("move_task_to_ready", %{"id" => id}, socket) do
    case Authorization.authorize_modify_for_task(socket, id) do
      {:ok, task} ->
        TaskActions.move_task_to_ready(socket, task)

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
    socket
    |> Authorization.authorize_move_task(task_id, old_column_id, new_column_id)
    |> handle_move_authorization(socket, new_position)
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
        ColumnActions.do_move_column(socket, column_id, column_ids)
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
        ColumnActions.do_toggle_field(socket, field_name)
    end
  end

  @impl true
  def handle_event("create_token", params, socket) do
    if socket.assigns.can_modify do
      ApiTokens.do_create_token(socket, params)
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
      ApiTokens.do_revoke_token(socket, id)
    else
      {:noreply,
       put_flash(socket, :error, gettext("You do not have permission to manage API tokens"))}
    end
  end

  def handle_event("delete_token", %{"id" => id}, socket) do
    if socket.assigns.can_modify do
      ApiTokens.do_delete_token(socket, id)
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
     |> BoardState.load_tasks_for_columns(columns)}
  end

  def handle_info({KanbanWeb.TaskLive.FormComponent, {:saved, _task}}, socket) do
    Process.send_after(self(), :clear_skip_reload, 100)
    {:noreply, assign(socket, :skip_next_reload, true)}
  end

  def handle_info({KanbanWeb.BoardLive.SettingsFormComponent, {:saved, board}}, socket) do
    user = socket.assigns.current_scope.user
    {:noreply, assign(socket, :board, BoardState.put_board_metrics(board, user))}
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
    BoardState.reload_board_data(socket)
  end

  @impl true
  def handle_info({Kanban.Tasks, :task_updated, _task}, socket) do
    if socket.assigns[:skip_next_reload],
      do: {:noreply, socket},
      else: BoardState.reload_board_data(socket)
  end

  @impl true
  def handle_info({Kanban.Tasks, :task_moved, task}, socket),
    do: BoardState.handle_remote_task_move(socket, task)

  @impl true
  def handle_info({Kanban.Tasks, :task_deleted, _task}, socket) do
    if socket.assigns[:skip_next_reload],
      do: {:noreply, socket},
      else: BoardState.reload_board_data(socket)
  end

  @impl true
  def handle_info({Kanban.Tasks, :task_status_changed, _task}, socket) do
    if socket.assigns[:skip_next_reload],
      do: {:noreply, socket},
      else: BoardState.reload_board_data(socket)
  end

  @impl true
  def handle_info({:task_updated, _task}, socket) do
    # Reload board when a task is updated via API (simple format)
    BoardState.reload_board_data(socket)
  end

  @impl true
  def handle_info({:task_moved_to_review, _task}, socket) do
    # Reload board when a task is moved to Review column via API
    BoardState.reload_board_data(socket)
  end

  @impl true
  def handle_info({:task_completed, _task}, socket) do
    # Reload board when a task is completed via API
    BoardState.reload_board_data(socket)
  end

  @impl true
  def handle_info({Kanban.Tasks, :task_reviewed, _task}, socket) do
    if socket.assigns[:skip_next_reload],
      do: {:noreply, socket},
      else: BoardState.reload_board_data(socket)
  end

  # Comment create/edit/delete broadcasts on this board topic too. The board
  # columns render no comments; the comment thread inside the task view and
  # task edit modals does, so forward the change to it. refresh/1 targets the
  # thread component directly (never ViewComponent, whose permission assigns a
  # partial send_update would reset) and skips a thread that is not open.
  @impl true
  def handle_info({Kanban.Tasks.Comments, :comment_changed, payload}, socket) do
    KanbanWeb.TaskLive.CommentThreadComponent.refresh(payload)
    {:noreply, socket}
  end

  # The comment thread is a live component, whose own flash LiveView drops,
  # so it sends its messages here to be shown.
  @impl true
  def handle_info({KanbanWeb.TaskLive.CommentThreadComponent, {:flash, kind, message}}, socket) do
    {:noreply, put_flash(socket, kind, message)}
  end

  @impl true
  def handle_info({KanbanWeb.BoardLive.LabelsManagerComponent, msg}, socket),
    do: {:noreply, KanbanWeb.BoardLive.LabelsManagerComponent.apply_parent_message(socket, msg)}

  @impl true
  def handle_info({:field_visibility_updated, new_visibility}, socket) do
    {:noreply, assign(socket, :field_visibility, new_visibility)}
  end

  @impl true
  def handle_info(:clear_skip_reload, socket) do
    {:noreply, assign(socket, :skip_next_reload, false)}
  end

  # Shared board-scoped id parser. Public because the extracted
  # KanbanWeb.BoardLive.Authorization module calls it (Show.parse_task_id/1)
  # and several stayers in this LiveView use it directly.
  @doc false
  def parse_task_id(id) when is_integer(id), do: {:ok, id}

  @doc false
  def parse_task_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  @doc false
  def parse_task_id(_), do: :error

  # Public helpers that moved out of this LiveView. Other modules, the board
  # template and the tests still call them here, so each one delegates.
  @doc false
  defdelegate assign_common_board_state(socket, board, user_access, columns), to: BoardState

  @doc false
  defdelegate handle_task_reorder(socket, column_id, task_id, new_position), to: TaskActions

  @doc false
  defdelegate handle_task_move(socket, task, new_column_id, new_position), to: TaskActions

  @doc "See `KanbanWeb.BoardLive.BoardState.show_move_to_ready?/4`."
  defdelegate show_move_to_ready?(can_modify, ready_column_id, column, task), to: BoardState

  @doc "See `KanbanWeb.BoardLive.BoardState.goal_hierarchy_column?/1`."
  defdelegate goal_hierarchy_column?(column), to: BoardState

  @doc "See `KanbanWeb.BoardLive.ColumnActions.translate_column_name/1`."
  defdelegate translate_column_name(column_name), to: ColumnActions

  @doc "See `KanbanWeb.BoardLive.ColumnActions.column_status/1`."
  defdelegate column_status(name), to: ColumnActions

  defp handle_move_authorization({:ok, task, old_col_id, new_col_id}, socket, new_position),
    do: Authorization.dispatch_authorized_move(socket, task, old_col_id, new_col_id, new_position)

  defp handle_move_authorization({:error, :filters_active}, socket, _new_position),
    do: FilterActions.reject_filtered_move(socket)

  defp handle_move_authorization({:error, :not_authorized}, socket, _new_position) do
    {:noreply,
     put_flash(socket, :error, gettext("You do not have permission to move tasks on this board"))}
  end

  defp handle_move_authorization({:error, :not_found}, socket, _new_position),
    do: {:noreply, put_flash(socket, :error, gettext("Failed to move task"))}
end
