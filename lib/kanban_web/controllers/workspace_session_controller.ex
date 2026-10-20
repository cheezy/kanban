defmodule KanbanWeb.WorkspaceSessionController do
  @moduledoc """
  The workspace switcher's `POST /workspace/switch`.

  The workspace id from the form is only a hint. `Kanban.Workspaces.Current.switchable/2`
  re-checks paid access through `Kanban.Plans` and reach through
  `Kanban.Workspaces.get_workspace/2`, and refuses archived and personal
  workspaces. On success the id is stored in the session as
  `current_workspace_id`; on any refusal — a free user, a workspace of another
  Organization, an archived or personal one, a missing or malformed id — the
  session is left unchanged and a generic flash says the workspace is not
  available, so a refusal reveals nothing about which workspaces exist.

  Both outcomes redirect to `/boards`, a fixed in-app path. The redirect is a
  full page load, so LiveViews mount again and `KanbanWeb.UserAuth` resolves
  the new workspace into `current_scope`.
  """
  use KanbanWeb, :controller

  alias Kanban.Workspaces.Current

  def switch(conn, params) do
    case Current.switchable(conn.assigns.current_scope, Map.get(params, "workspace_id")) do
      {:ok, workspace} ->
        conn
        |> put_session(:current_workspace_id, workspace.id)
        |> redirect(to: ~p"/boards")

      :error ->
        conn
        |> put_flash(:error, gettext("That workspace is not available."))
        |> redirect(to: ~p"/boards")
    end
  end
end
