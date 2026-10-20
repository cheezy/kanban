defmodule KanbanWeb.API.BoardReadAccess do
  @moduledoc """
  The live board-read check for API reads made with a board token.

  A board token is bound to one board when it is created, but its user can
  later lose access to that board: removed from the board, removed as
  org-admin of the Organization whose workspace holds it, or gone from the
  Organization. Not every one of those paths revokes the token. So every API
  read re-checks, on every request, that the token's user still has effective
  access to the token's board — `Kanban.Boards.get_user_access/2`, the same
  function the write endpoints use, which counts a `board_users` row and the
  owner access an org-admin derives (`Kanban.Workspaces.Policy`). Any access
  level is enough to read, `:read_only` included. A public read-only board
  gets no exception: the token's user must still have access of their own.

  A refused read is the API's documented board-membership refusal,
  `403` with the `KanbanWeb.API.TaskErrors.error_body/1` body for
  `:not_authorized`, and a `permission_denied` audit event with
  `gate: :api_board_read`. It is not a `401`: the token itself is still valid.

  Workspace tokens pass here untouched: `KanbanWeb.Plugs.AuthenticateApiToken`
  already re-derives their board access on every request. A disabled user never
  gets this far, because the token plug refuses their tokens with `401`.

  Write endpoints keep their own live checks and error bodies
  (`KanbanWeb.API.TaskActions.authorize_board_write/2` and friends), so this
  is only applied to reads: as a plug on the REST read actions, and through
  `authorize/1` by the read tools in `KanbanWeb.MCP.Tools`.
  """

  @behaviour Plug

  import Plug.Conn, only: [halt: 1]

  alias Kanban.ApiTokens.ApiToken
  alias Kanban.Boards
  alias KanbanWeb.API.TaskErrors

  @gate :api_board_read

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case authorize(conn) do
      :ok -> conn
      {:error, reason} -> conn |> TaskErrors.render_error(reason) |> halt()
    end
  end

  @doc """
  `:ok` when the request's token may read its board, else
  `{:error, :not_authorized}` (after writing the `permission_denied` audit
  event).

  A board token passes while its user has any effective access to its board.
  A workspace token always passes: its board was checked when the request
  selected it, and a board-optional route has no board to check.
  """
  @spec authorize(Plug.Conn.t()) :: :ok | {:error, :not_authorized}
  def authorize(%Plug.Conn{
        assigns: %{
          api_token: %ApiToken{workspace_id: nil},
          current_board: %{id: board_id},
          current_user: %{id: user_id}
        }
      }) do
    if Boards.get_user_access(board_id, user_id), do: :ok, else: refuse(user_id)
  end

  def authorize(%Plug.Conn{assigns: %{api_token: %ApiToken{workspace_id: workspace_id}}})
      when not is_nil(workspace_id),
      do: :ok

  def authorize(%Plug.Conn{assigns: assigns}), do: refuse(user_id(assigns))

  defp refuse(user_id) do
    Kanban.AuditLog.event(:permission_denied, user_id: user_id, gate: @gate)
    {:error, :not_authorized}
  end

  defp user_id(%{current_user: %{id: id}}), do: id
  defp user_id(_assigns), do: nil
end
