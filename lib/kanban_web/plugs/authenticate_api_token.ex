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

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, token} <- extract_token(conn),
         {:ok, api_token} <- ApiTokens.get_api_token_by_token(token) do
      conn
      |> assign(:current_user, api_token.user)
      |> assign(:current_board, api_token.board)
      |> assign(:api_token, api_token)
    else
      {:error, :missing_token} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Missing or invalid Authorization header"})
        |> halt()

      {:error, :not_found} ->
        emit_auth_failed_telemetry(conn, "token_not_found")

        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid API token"})
        |> halt()

      {:error, :revoked} ->
        emit_auth_failed_telemetry(conn, "token_revoked")

        conn
        |> put_status(:unauthorized)
        |> json(%{error: "API token has been revoked"})
        |> halt()
    end
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
