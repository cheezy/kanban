defmodule KanbanWeb.BoardLive.ColumnActions do
  @moduledoc """
  Column and board-display handlers for `KanbanWeb.BoardLive.Show`, extracted
  from the LiveView to keep it under the module-size guideline: deleting and
  reordering columns, toggling field visibility, and the column name and
  status helpers the board template and `KanbanWeb.BoardLive.Goals` use. The
  owner and AI-board checks stay in the LiveView's `handle_event/3` clauses.
  Flash strings are asserted in tests and shown to users — do not reword.
  """

  use Gettext, backend: KanbanWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, push_event: 3, stream: 4, stream_delete: 3]

  alias Kanban.Boards
  alias Kanban.Columns
  alias KanbanWeb.BoardLive.BoardState
  alias KanbanWeb.BoardLive.Show

  def do_delete_column(socket, raw_id) do
    with {:ok, column_id} <- Show.parse_task_id(raw_id),
         %Columns.Column{} = column <-
           Columns.get_column_for_board(column_id, socket.assigns.board.id) do
      perform_column_deletion(socket, column)
    else
      _ ->
        {:noreply, put_flash(socket, :error, gettext("Column not found on this board"))}
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

  def do_toggle_field(socket, field_name) do
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

  def do_move_column(socket, column_id, column_ids) do
    require Logger

    column_ids = Enum.map(column_ids, &String.to_integer/1)

    Logger.info("Move column event: column_id=#{column_id}, new_order=#{inspect(column_ids)}")

    Columns.reorder_columns(socket.assigns.board, column_ids)

    columns = Columns.list_columns(socket.assigns.board)

    {:noreply,
     socket
     |> push_event("move_column_success", %{})
     |> stream(:columns, columns, reset: true)
     |> BoardState.load_tasks_for_columns(columns)}
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
end
