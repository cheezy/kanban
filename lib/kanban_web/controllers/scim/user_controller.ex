defmodule KanbanWeb.SCIM.UserController do
  @moduledoc """
  The SCIM `/Users` endpoints (W2247). The token's Organization comes from
  `conn.assigns.scim_token` (`KanbanWeb.Plugs.AuthenticateScimToken`); every
  rule lives in `Kanban.SCIM`.

  After a deprovisioning commits, the user's sessions are disconnected here:
  a disabled account's deleted sessions for good, anyone else's open pages so
  they reconnect and re-check their access.
  """
  use KanbanWeb, :controller

  alias Kanban.SCIM
  alias KanbanWeb.SCIM.Response
  alias KanbanWeb.UserAuth

  action_fallback KanbanWeb.SCIM.FallbackController

  def index(conn, params) do
    with {:ok, page} <- SCIM.list_users(conn.assigns.scim_token, params) do
      resources = Enum.map(page.records, &Response.user/1)
      Response.send_json(conn, 200, Response.list(page, resources))
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, record} <- SCIM.get_user(conn.assigns.scim_token, id) do
      Response.send_json(conn, 200, Response.user(record))
    end
  end

  def create(conn, _params) do
    with {:ok, record} <- SCIM.create_user(conn.assigns.scim_token, conn.body_params) do
      conn
      |> put_resp_header("location", Response.user_location(record.user.id))
      |> Response.send_json(201, Response.user(record))
    end
  end

  def update(conn, %{"id" => id}) do
    with {:ok, record, sessions} <-
           SCIM.replace_user(conn.assigns.scim_token, id, conn.body_params) do
      disconnect(sessions)
      Response.send_json(conn, 200, Response.user(record))
    end
  end

  def patch(conn, %{"id" => id}) do
    with {:ok, record, sessions} <- SCIM.patch_user(conn.assigns.scim_token, id, conn.body_params) do
      disconnect(sessions)
      Response.send_json(conn, 200, Response.user(record))
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, sessions} <- SCIM.delete_user(conn.assigns.scim_token, id) do
      disconnect(sessions)
      send_resp(conn, 204, "")
    end
  end

  defp disconnect({:revoked, tokens}), do: UserAuth.disconnect_sessions(tokens)
  defp disconnect({:live, tokens}), do: UserAuth.disconnect_live_sessions(tokens)
  defp disconnect(:none), do: :ok
end
