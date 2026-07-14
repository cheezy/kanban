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

  Note: Tokens are scoped to both a user and a board. Each user has separate
  tokens for each board they have access to.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Kanban.ApiTokens
  alias Kanban.RateLimit

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
      |> assign(:current_board, api_token.board)
      |> assign(:api_token, api_token)
    else
      {:error, reason} = error -> handle_auth_failure(conn, reason, error)
    end
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

  defp halt_with_auth_error(conn, {:error, :missing_token}) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "Missing or invalid Authorization header"})
    |> halt()
  end

  defp halt_with_auth_error(conn, {:error, :not_found}) do
    emit_auth_failed_telemetry(conn, "token_not_found")

    conn
    |> put_status(:unauthorized)
    |> json(%{error: "Invalid API token"})
    |> halt()
  end

  defp halt_with_auth_error(conn, {:error, :revoked}) do
    emit_auth_failed_telemetry(conn, "token_revoked")

    conn
    |> put_status(:unauthorized)
    |> json(%{error: "API token has been revoked"})
    |> halt()
  end

  defp halt_with_auth_error(conn, {:error, :expired}) do
    emit_auth_failed_telemetry(conn, "token_expired")

    conn
    |> put_status(:unauthorized)
    |> json(%{error: "API token has expired"})
    |> halt()
  end

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        {:ok, String.trim(token)}

      _ ->
        {:error, :missing_token}
    end
  end

  defp emit_auth_failed_telemetry(conn, reason) do
    :telemetry.execute(
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
