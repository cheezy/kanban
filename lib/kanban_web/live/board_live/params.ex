defmodule KanbanWeb.BoardLive.Params do
  @moduledoc """
  `handle_params/3` resolution for `KanbanWeb.BoardLive.Show`, extracted from
  the LiveView to keep it under the module-size guideline. Looks the board up
  for the current user, subscribes to its updates, and resolves each
  live_action's column or task strictly within that board, redirecting with a
  flash when something is missing or the viewer may not open a task form
  (D110). Socket-in, `{:noreply, socket}`-out.
  """

  use Gettext, backend: KanbanWeb.Gettext
  use KanbanWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3]

  import Phoenix.LiveView,
    only: [connected?: 1, push_navigate: 2, push_patch: 2, put_flash: 3, stream: 4]

  alias Kanban.Boards
  alias Kanban.Columns
  alias Kanban.Tasks
  alias KanbanWeb.BoardLive.Authorization
  alias KanbanWeb.BoardLive.BoardState
  alias KanbanWeb.BoardLive.FilterActions
  alias KanbanWeb.BoardLive.Show

  def with_board(socket, id, fun) do
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

  def handle_board_not_found(socket) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("Board not found"))
     |> push_navigate(to: ~p"/boards")}
  end

  # handle_params runs on every patch (each filter change, opening a modal),
  # and a second subscribe to the same topic would deliver every broadcast
  # twice. Subscribe only when this socket has not already loaded this board.
  def subscribe_to_board_updates(socket, board_id) do
    if connected?(socket) and not match?(%{id: ^board_id}, socket.assigns[:board]) do
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{board_id}")
    end
  end

  # The column routes (:new_column, :edit_column, :new_task) gate on the
  # live_action and the viewer's access before loading the column.
  def resolve_column_action(socket, board, user_access, column_id) do
    case Authorization.check_column_action_authorization(
           socket.assigns.live_action,
           user_access,
           board
         ) do
      :ok ->
        assign_board_with_column(socket, board, user_access, column_id)

      {:error, message} ->
        {:noreply,
         socket
         |> put_flash(:error, message)
         |> push_patch(to: ~p"/boards/#{board}")}
    end
  end

  # Serves :new_task (task form) and :edit_column (already owner-gated upstream by
  # check_column_action_authorization). The task-form gate is a no-op for the owner
  # editing a column, and blocks a read-only viewer opening the new-task form (D110).
  def assign_board_with_column(socket, board, user_access, column_id) do
    gate_task_form(socket, board, user_access, fn ->
      do_assign_board_with_column(socket, board, user_access, column_id)
    end)
  end

  # :new_goal — header "New goal" entry point. Same D110 gate as :new_task;
  # the target column is resolved server-side to the board's leftmost
  # (position 0) column rather than coming from the URL.
  def resolve_new_goal(socket, board, user_access) do
    gate_task_form(socket, board, user_access, fn ->
      columns = Columns.list_columns(board)

      case List.first(columns) do
        nil ->
          {:noreply,
           socket
           |> put_flash(:error, gettext("Column not found on this board"))
           |> push_patch(to: ~p"/boards/#{board}")}

        column ->
          {:noreply,
           socket
           |> BoardState.assign_common_board_state(board, user_access, columns)
           |> assign(:column, column)
           |> assign(:column_id, column.id)}
      end
    end)
  end

  defp do_assign_board_with_column(socket, board, user_access, column_id) do
    with {:ok, column_id_int} <- Show.parse_task_id(column_id),
         %Columns.Column{} = column <- Columns.get_column_for_board(column_id_int, board.id) do
      columns = Columns.list_columns(board)

      {:noreply,
       socket
       |> BoardState.assign_common_board_state(board, user_access, columns)
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
     |> assign(:page_title, BoardState.page_title(socket.assigns.live_action))
     |> assign(:board, board)
     |> assign(:user_access, user_access)
     |> assign(:can_modify, user_access in [:owner, :modify])
     |> assign(:is_owner, user_access == :owner)
     |> assign(:field_visibility, board.field_visibility || %{})
     |> assign(:column, column)
     |> assign(:task, task)
     |> assign(:has_columns, not Enum.empty?(columns))
     |> stream(:columns, columns, reset: true)
     |> BoardState.load_tasks_for_columns(columns)}
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
    |> assign(:page_title, BoardState.page_title(socket.assigns.live_action))
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
      BoardState.load_tasks_for_columns(socket, columns)
    end
  end

  # D110: read-only viewers must not reach the task create/edit form. Gates the
  # task-form live_actions on modify access; the FormComponent save handler is the
  # authoritative server-side check, this is the redirect-before-render layer.
  defp gate_task_form(socket, board, user_access, fun) do
    case Authorization.authorize_task_form(user_access) do
      :ok ->
        fun.()

      {:error, message} ->
        {:noreply,
         socket
         |> put_flash(:error, message)
         |> push_patch(to: ~p"/boards/#{board}")}
    end
  end

  def resolve_column_and_task(socket, board, user_access, column_id, task_id) do
    gate_task_form(socket, board, user_access, fn ->
      case fetch_column_and_task(board, column_id, task_id) do
        {:ok, column, task} ->
          assign_column_and_task(socket, board, user_access, column, task)

        :error ->
          {:noreply,
           socket
           |> put_flash(:error, gettext("Column or task not found on this board"))
           |> push_patch(to: ~p"/boards/#{board}")}
      end
    end)
  end

  defp fetch_column_and_task(board, column_id, task_id) do
    with {:ok, column_id_int} <- Show.parse_task_id(column_id),
         {:ok, task_id_int} <- Show.parse_task_id(task_id),
         %Columns.Column{} = column <- Columns.get_column_for_board(column_id_int, board.id),
         %Tasks.Task{} = task <- Tasks.get_task_for_board(task_id_int, board.id) do
      {:ok, column, task}
    else
      _ -> :error
    end
  end

  def resolve_task_only(socket, board, user_access, task_id) do
    gate_task_form(socket, board, user_access, fn ->
      with {:ok, task_id_int} <- Show.parse_task_id(task_id),
           %Tasks.Task{} = task <- Tasks.get_task_for_board(task_id_int, board.id) do
        assign_task_only(socket, board, user_access, task)
      else
        _ ->
          {:noreply,
           socket
           |> put_flash(:error, gettext("Task not found on this board"))
           |> push_patch(to: ~p"/boards/#{board}")}
      end
    end)
  end

  # The plain board URL carries the filter bar's query params (W2235); they
  # are read here on every :show patch so the URL stays the source of truth.
  def resolve_default_board_view(socket, board, user_access, params \\ %{}) do
    case Authorization.check_new_column_authorization(
           socket.assigns.live_action,
           user_access,
           board
         ) do
      :ok ->
        same_board? = same_board_show?(socket, board)
        {socket, filters_changed?} = maybe_assign_filters(socket, board, params)

        if same_board? do
          BoardState.refresh_board_tasks(socket, board, filters_changed?)
        else
          BoardState.assign_board_state(socket, board, user_access)
        end

      {:error, message} ->
        {:noreply,
         socket
         |> put_flash(:error, message)
         |> push_patch(to: ~p"/boards/#{board}")}
    end
  end

  defp maybe_assign_filters(%{assigns: %{live_action: :show}} = socket, board, params),
    do: FilterActions.assign_filters(socket, board, params)

  defp maybe_assign_filters(socket, _board, _params), do: {socket, false}

  defp same_board_show?(socket, board) do
    socket.assigns.live_action == :show and
      Map.get(socket.assigns, :board) != nil and
      socket.assigns.board.id == board.id
  end
end
