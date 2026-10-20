defmodule KanbanWeb.Plugs.AuthenticateApiToken do
  @moduledoc """
  Plug to authenticate API requests using Bearer tokens.

  This plug extracts the Bearer token from the Authorization header,
  validates it against the database, and assigns the authenticated
  user, board, and api_token to the conn if valid.

  ## Usage

  In your router:

      pipeline :api do
        plug :accepts, ["json"]
        plug KanbanWeb.Plugs.AuthenticateApiToken
      end

  The plug will:
  - Look for "Authorization: Bearer <token>" header
  - Validate the token against the database
  - Check that the token is not revoked
  - Assign :current_user, :current_board, and :api_token to conn.assigns
  - Return 401 Unauthorized if token is invalid or missing

  ## Board tokens and workspace tokens

  A board token is scoped to a user and one board, and `:current_board` is
  that board. It needs no selector, but a request that sends one anyway must
  name the token's own board: an `X-Stride-Board` header or `board_id`
  parameter naming another board is refused with 400, as is an ambiguous
  selector, so an agent configured for one board while holding another
  board's token finds out instead of writing to the token's board. On a
  board-optional route the selector is ignored, as it is for a workspace
  token. This plug does not check that the
  token's user can still use that board: reads re-check it in
  `KanbanWeb.API.BoardReadAccess` and writes in
  `KanbanWeb.API.BoardWriteAccess`, so each answers with its documented
  `403` rather than a `401`.

  A workspace token (W2220) is scoped to a user and an Organization workspace,
  so each request names its board with the `X-Stride-Board` header or the
  `board_id` parameter (`KanbanWeb.Plugs.AuthenticateApiToken.BoardSelector`).
  The board is re-checked on every request
  (`Kanban.ApiTokens.fetch_workspace_board/2`): it must be in the token's
  workspace and the token's user must still be able to modify it. Then
  `:current_board` is assigned exactly as for a board token, so controllers
  and the MCP server need nothing new. The request is refused with:

    * 400 when it names no board, names two different ones, or repeats the
      header or the query-string `board_id`, and
    * 404 with one fixed body for every board it may not use — a board that
      does not exist, one in another workspace or Organization, one its user
      cannot modify — so the response never tells them apart.

  These are not authentication failures: the token is valid, so they are not
  counted by the failed-authentication rate limit. Routes marked with
  `KanbanWeb.Plugs.BoardSelectorOptional` (`GET /api/boards`) take a workspace
  token without a selector and get no `:current_board`.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Kanban.ApiTokens
  alias Kanban.ApiTokens.ApiToken
  alias Kanban.ApiTokens.DeniedAudit
  alias Kanban.RateLimit
  alias KanbanWeb.Plugs.AuthenticateApiToken.BoardSelector

  def init(opts), do: opts

  def call(conn, _opts) do
    # Throttle a token-guessing flood by source IP before touching the DB. Only
    # failed authentications are counted, so legitimate high-frequency API
    # traffic with a valid token is never limited.
    case RateLimit.peek(:api_token, ip: conn.remote_ip) do
      {:error, {:rate_limited, retry_after_ms}} ->
        halt_rate_limited(conn, retry_after_ms)

      :ok ->
        authenticate(conn)
    end
  end

  defp authenticate(conn) do
    with {:ok, token} <- extract_token(conn),
         {:ok, api_token} <- ApiTokens.get_api_token_by_token(token) do
      conn
      |> assign(:current_user, api_token.user)
      |> assign(:api_token, api_token)
      |> assign_board(api_token)
    else
      {:error, reason} = error -> handle_auth_failure(conn, reason, error)
    end
  end

  defp assign_board(
         %Plug.Conn{private: %{stride_board_selector: :optional}} = conn,
         %ApiToken{workspace_id: nil} = api_token
       ),
       do: assign(conn, :current_board, api_token.board)

  defp assign_board(conn, %ApiToken{workspace_id: nil, board_id: board_id} = api_token) do
    case BoardSelector.read(conn) do
      :none -> assign(conn, :current_board, api_token.board)
      {:ok, ^board_id} -> assign(conn, :current_board, api_token.board)
      {:ok, _other} -> halt_board_error(conn, :board_selector_mismatch)
      :conflict -> halt_board_error(conn, :board_selector_conflict)
    end
  end

  defp assign_board(%Plug.Conn{private: %{stride_board_selector: :optional}} = conn, _api_token),
    do: conn

  defp assign_board(conn, %ApiToken{} = api_token) do
    with {:ok, selector} <- BoardSelector.read(conn),
         {:ok, board} <- ApiTokens.fetch_workspace_board(api_token, selector) do
      assign(conn, :current_board, board)
    else
      :none -> halt_board_error(conn, :board_selector_missing)
      :conflict -> halt_board_error(conn, :board_selector_conflict)
      :error -> halt_board_error(conn, :board_not_found)
    end
  end

  defp halt_board_error(conn, :board_selector_missing) do
    emit_auth_failed_telemetry(conn, "board_selector_missing")

    conn
    |> put_status(:bad_request)
    |> json(%{
      error: "Board selector required",
      message:
        "A workspace token must name a board with the X-Stride-Board header or the board_id parameter. GET /api/boards lists the boards it can use."
    })
    |> halt()
  end

  defp halt_board_error(conn, :board_selector_conflict) do
    emit_auth_failed_telemetry(conn, "board_selector_conflict")

    conn
    |> put_status(:bad_request)
    |> json(%{
      error: "Conflicting board selectors",
      message:
        "The X-Stride-Board header, the query-string board_id and the body board_id must name the same board, and the header and the query-string board_id may each be sent once."
    })
    |> halt()
  end

  # The token holder already knows their token's board, so naming it, or
  # saying the selector named another one, discloses nothing; the other board
  # is never looked up.
  defp halt_board_error(conn, :board_selector_mismatch) do
    emit_auth_failed_telemetry(conn, "board_selector_mismatch")

    conn
    |> put_status(:bad_request)
    |> json(%{
      error: "Board selector does not match token",
      message:
        "A board token acts only on the board it was created for. Remove the X-Stride-Board header and board_id parameter, or make them name that board."
    })
    |> halt()
  end

  # One fixed body for a board that does not exist, one in another workspace
  # or Organization, and one the token's user may not modify, so the response
  # never says which (cross-tenant enumeration).
  defp halt_board_error(conn, :board_not_found) do
    emit_auth_failed_telemetry(conn, "board_not_found")

    DeniedAudit.record(conn.assigns.api_token, conn.assigns.current_user.id, :api_board_selector)

    conn
    |> put_status(:not_found)
    |> json(%{error: "Board not found"})
    |> halt()
  end

  defp handle_auth_failure(conn, reason, error) do
    RateLimit.record_failure(:api_token, ip: conn.remote_ip)
    Kanban.AuditLog.event(:api_token_auth_failed, ip: conn.remote_ip, reason: reason)
    halt_with_auth_error(conn, error)
  end

  defp halt_rate_limited(conn, retry_after_ms) do
    emit_auth_failed_telemetry(conn, "rate_limited")

    conn
    |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms, 1000) + 1))
    |> put_status(:too_many_requests)
    |> json(%{error: "Too many requests"})
    |> halt()
  end

  # A request with no Authorization header, or one that is not a Bearer
  # header, reports reason "missing_token".
  defp halt_with_auth_error(conn, {:error, :missing_token}) do
    emit_auth_failed_telemetry(conn, "missing_token")

    conn
    |> put_status(:unauthorized)
    |> json(%{error: "Missing or invalid Authorization header"})
    |> halt()
  end

  # not_found / revoked / expired all return an IDENTICAL body. Distinct
  # strings ("Invalid" vs "revoked" vs "expired") told a caller holding a
  # candidate token whether that string ever corresponded to a real token —
  # token-lifecycle metadata disclosure (W1676 L2). The specific reason is
  # preserved only in server-side telemetry. `missing_token` is left distinct
  # on purpose: it is a request-format signal, not token-state disclosure.
  defp halt_with_auth_error(conn, {:error, reason})
       when reason in [:not_found, :revoked, :expired] do
    emit_auth_failed_telemetry(conn, telemetry_reason(reason))

    conn
    |> put_status(:unauthorized)
    |> json(%{error: "Invalid API token"})
    |> halt()
  end

  # The telemetry reason names the disabled owner so operators can see it, while
  # the response stays the generic invalid-token error rather than reporting the
  # account's state back to the caller.
  defp halt_with_auth_error(conn, {:error, :user_disabled}) do
    emit_auth_failed_telemetry(conn, "user_disabled")

    conn
    |> put_status(:unauthorized)
    |> json(%{error: "Invalid API token"})
    |> halt()
  end

  defp telemetry_reason(:not_found), do: "token_not_found"
  defp telemetry_reason(:revoked), do: "token_revoked"
  defp telemetry_reason(:expired), do: "token_expired"

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        {:ok, String.trim(token)}

      _ ->
        {:error, :missing_token}
    end
  end

  defp emit_auth_failed_telemetry(conn, reason) do
    Kanban.Telemetry.emit(
      [:kanban, :api, :auth_failed],
      %{count: 1},
      %{
        reason: reason,
        path: conn.request_path,
        method: conn.method
      }
    )
  end
end
