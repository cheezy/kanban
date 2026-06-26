defmodule KanbanWeb.ArchiveExportController do
  @moduledoc """
  Serves a CSV export of a board's archived tasks as a file download.

  Mirrors `KanbanWeb.MetricsPdfController`: it authorizes the board for the
  signed-in user via `Kanban.Boards.get_board/2`, then streams a `text/csv`
  attachment built entirely in the `Kanban.Archives` context (no Ecto or CSV
  logic in the controller). A board the user cannot access resolves to
  `{:error, :not_found}` and redirects to the boards index — the archive of
  another board is never disclosed.
  """
  use KanbanWeb, :controller

  alias Kanban.Archives
  alias Kanban.Boards

  def export(conn, %{"id" => board_id}) do
    user = conn.assigns.current_scope.user

    case Boards.get_board(board_id, user) do
      {:ok, board} ->
        csv = Archives.export_csv_for_board(board.id)

        conn
        |> put_resp_content_type("text/csv")
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="#{export_filename(board)}")
        )
        |> send_resp(200, csv)

      {:error, :not_found} ->
        conn
        |> put_flash(:error, gettext("Board not found"))
        |> redirect(to: ~p"/boards")
    end
  end

  # Sanitize the board name to a safe filename token (alphanumerics, dash,
  # underscore only) so it cannot break the content-disposition header.
  defp export_filename(board) do
    name = String.replace(board.name, ~r/[^a-zA-Z0-9_-]/, "_")
    "#{name}_archive_#{Date.utc_today()}.csv"
  end
end
