defmodule KanbanWeb.API.OpenApiController do
  @moduledoc """
  Serves the Stride API's OpenAPI 3.1 document at `GET /api/openapi.json`
  (W2225).

  Public — routed through the `:api_public` pipeline next to
  `GET /api/agent/onboarding`, because the spec is how a new client learns how
  to authenticate in the first place. It contains no tokens and no
  undocumented routes.

  The bytes are served exactly as stored in `priv/openapi/stride-api.json`
  (no decode/re-encode round trip). The document changes only on deploy, so
  it is marked cacheable for an hour.
  """
  use KanbanWeb, :controller

  alias KanbanWeb.API.OpenApiSpec

  require Logger

  @cache_control "public, max-age=3600"

  def show(conn, _params), do: respond(conn, OpenApiSpec.fetch())

  # Exposed for testing: the error branch cannot be reached through the
  # router without deleting the priv file the rest of the suite reads.
  @doc false
  def respond(conn, {:ok, body}) do
    conn
    |> put_resp_header("cache-control", @cache_control)
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  def respond(conn, {:error, reason}) do
    Logger.error("OpenAPI spec unavailable at priv/openapi/stride-api.json: #{inspect(reason)}")

    conn
    |> put_status(:internal_server_error)
    |> json(%{error: "OpenAPI specification unavailable"})
  end
end
