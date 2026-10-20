defmodule KanbanWeb.WorkspaceExportController do
  @moduledoc """
  Downloads a finished workspace export archive (W2222).

  Authorization is derived from the signed-in user on every request, never
  from the session's current workspace and never from the URL: the export id
  is only a hint, looked up by
  `Kanban.Workspaces.Export.get_export_for_download/2`, which re-reads the
  user and requires an enabled org-admin of the export's own workspace's
  Organization. The file served is the path the export worker stored, inside
  the export directory; no part of it comes from the request, and the
  download filename is built from a literal and the integer export id.

  Every refusal — a member, a guest, an outsider, a former org-admin, another
  Organization's export, an unfinished, failed or expired export, a missing
  file or a malformed id — is the same 404, so the response never reveals
  whether an export exists.
  """

  use KanbanWeb, :controller

  alias Kanban.Workspaces.Export

  # Timed as the [:kanban, :export] span. Only the export kind and file format
  # are reported: never the workspace, the export id or the path.
  def download(conn, %{"id" => id}) do
    case Export.get_export_for_download(conn.assigns.current_scope.user, id) do
      {:ok, export} ->
        Kanban.Telemetry.span([:kanban, :export], %{kind: :workspace_export, format: :zip}, fn ->
          {send_archive(conn, export), %{kind: :workspace_export, format: :zip}}
        end)

      {:error, :not_found} ->
        not_found(conn)
    end
  end

  def download(conn, _params), do: not_found(conn)

  # sobelow_skip ["Traversal.SendDownload"]
  defp send_archive(conn, export) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> send_download({:file, export.file_path},
      filename: "stride-workspace-export-#{export.id}.zip",
      content_type: "application/zip",
      disposition: :attachment
    )
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> put_view(html: KanbanWeb.ErrorHTML)
    |> render(:"404")
  end
end
