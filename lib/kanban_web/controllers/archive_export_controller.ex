defmodule KanbanWeb.ArchiveExportController do
  @moduledoc """
  Serves a CSV export of a board's archived tasks as a file download.

  Mirrors `KanbanWeb.MetricsPdfController`: it authorizes the board for the
  signed-in user via `Kanban.Boards.get_board/2`, then streams a `text/csv`
  attachment built entirely in the `Kanban.Archives` context (no Ecto or CSV
  logic in the controller). A board the user cannot access resolves to
  `{:error, :not_found}` and redirects to the boards index — the archive of
  another board is never disclosed.

  ## HEAD

  A `HEAD` request (`KanbanWeb.Plugs.HeadRequest`) is authorized exactly as a
  `GET` and gets the same status, content type and content-disposition with no
  body, but it never calls `Kanban.Archives.export_csv_for_board/1`: no CSV is
  built and no `[:kanban, :export]` span is emitted, so export metrics count
  only real downloads.
  """
  use KanbanWeb, :controller

  alias Kanban.Archives
  alias Kanban.Boards
  alias KanbanWeb.Plugs.HeadRequest

  def export(conn, %{"id" => board_id}) do
    user = conn.assigns.current_scope.user

    case Boards.get_board(board_id, user) do
      {:ok, board} ->
        answer_export(conn, board, HeadRequest.head?(conn))

      {:error, :not_found} ->
        conn
        |> put_flash(:error, gettext("Board not found"))
        |> redirect(to: ~p"/boards")
    end
  end

  # A HEAD is authorized by the board lookup above exactly as a GET and gets
  # the same status and headers, but no body: the server drops it, so it is
  # not an export. No header needs the CSV (there is no content-length), so
  # Archives.export_csv_for_board/1, which owns the span, is never called.
  defp answer_export(conn, board, true) do
    conn
    |> put_export_headers(board)
    |> send_resp(200, "")
  end

  # Archives.export_csv_for_board/1 builds the CSV inside the
  # [:kanban, :export] span (kind: :archive_csv).
  defp answer_export(conn, board, false) do
    csv = Archives.export_csv_for_board(board.id)

    conn
    |> put_export_headers(board)
    |> send_resp(200, csv)
  end

  # The content type and content-disposition a GET sends with the CSV, shared
  # with the HEAD branch so the two cannot drift apart.
  defp put_export_headers(conn, board) do
    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header(
      "content-disposition",
      ~s(attachment; filename="#{export_filename(board)}")
    )
  end

  # Sanitize the board name to a safe filename token (alphanumerics, dash,
  # underscore only) so it cannot break the content-disposition header.
  defp export_filename(board) do
    name = String.replace(board.name, ~r/[^a-zA-Z0-9_-]/, "_")
    "#{name}_archive_#{Date.utc_today()}.csv"
  end
end
