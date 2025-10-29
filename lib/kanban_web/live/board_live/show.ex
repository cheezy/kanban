defmodule KanbanWeb.BoardLive.Show do
  use KanbanWeb, :live_view

  alias Kanban.Boards
  alias Kanban.Columns

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id, "column_id" => column_id}, _, socket) do
    user = socket.assigns.current_scope.user
    board = Boards.get_board!(id, user)
    columns = Columns.list_columns(board)
    column = Columns.get_column!(column_id)

    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:board, board)
     |> assign(:column, column)
     |> assign(:has_columns, length(columns) > 0)
     |> stream(:columns, columns)}
  end

  def handle_params(%{"id" => id}, _, socket) do
    user = socket.assigns.current_scope.user
    board = Boards.get_board!(id, user)
    columns = Columns.list_columns(board)

    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:board, board)
     |> assign(:has_columns, length(columns) > 0)
     |> stream(:columns, columns)}
  end

  @impl true
  def handle_event("delete_column", %{"id" => id}, socket) do
    column = Columns.get_column!(id)

    case Columns.delete_column(column) do
      {:ok, _column} ->
        columns = Columns.list_columns(socket.assigns.board)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Column deleted successfully"))
         |> assign(:has_columns, length(columns) > 0)
         |> stream_delete(:columns, column)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to delete column"))}
    end
  end

  @impl true
  def handle_info({KanbanWeb.ColumnLive.FormComponent, {:saved, _column}}, socket) do
    columns = Columns.list_columns(socket.assigns.board)

    {:noreply,
     socket
     |> assign(:has_columns, length(columns) > 0)
     |> stream(:columns, columns, reset: true)}
  end

  defp page_title(:show), do: "Show Board"
  defp page_title(:new_column), do: "New Column"
  defp page_title(:edit_column), do: "Edit Column"
end
