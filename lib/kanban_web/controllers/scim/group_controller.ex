defmodule KanbanWeb.SCIM.GroupController do
  @moduledoc """
  The SCIM `/Groups` endpoints (W2247): the token's Organization's
  workspaces. Only member changes are accepted; creating, replacing or
  deleting a Group is refused, since org-admins manage workspaces in the org
  console.
  """
  use KanbanWeb, :controller

  alias Kanban.SCIM
  alias KanbanWeb.SCIM.Response

  action_fallback KanbanWeb.SCIM.FallbackController

  def index(conn, params) do
    with {:ok, page} <- SCIM.list_groups(conn.assigns.scim_token, params) do
      resources = Enum.map(page.records, &Response.group/1)
      Response.send_json(conn, 200, Response.list(page, resources))
    end
  end

  def show(conn, %{"id" => id} = params) do
    with {:ok, record} <- SCIM.get_group(conn.assigns.scim_token, id, params) do
      Response.send_json(conn, 200, Response.group(record))
    end
  end

  def patch(conn, %{"id" => id}) do
    with :ok <- SCIM.patch_group(conn.assigns.scim_token, id, conn.body_params) do
      send_resp(conn, 204, "")
    end
  end

  def unsupported(_conn, _params), do: {:error, :unsupported}
end
