defmodule KanbanWeb.Plugs.BearerChallenge do
  @moduledoc """
  The `www-authenticate` challenge a Bearer-protected route sends with every
  `401` (RFC 6750 §3), so an HTTP or MCP client can tell "this route needs a
  token" from any other failure.

  `KanbanWeb.Plugs.AuthenticateApiToken` (the agent API, `POST /api/mcp`
  included) and `KanbanWeb.Plugs.AuthenticateDeviceToken` (`/api/me`) use it
  for every `401` they send, and `KanbanWeb.API.Me.FallbackController` uses
  it for the `401` a write gets when its device was revoked mid-request:

    * `:no_token` — no usable Bearer header was sent: `Bearer`, with no error
      attribute, as RFC 6750 §3.1 asks for a request that carried no
      authentication;
    * `:invalid_token` — a token was sent and refused, for whatever reason:
      `Bearer error="invalid_token"`.

  The challenge never names a realm, never echoes the token and never says
  why a token was refused, so it discloses no more than the JSON body
  already does. It is not sent with a `403` or a `429`. The SCIM plug sends
  its own challenge (`KanbanWeb.Plugs.AuthenticateScimToken`).
  """

  import Plug.Conn

  @header "www-authenticate"

  @doc """
  Puts the challenge for `kind` on the response.
  """
  @spec put_challenge(Plug.Conn.t(), :no_token | :invalid_token) :: Plug.Conn.t()
  def put_challenge(conn, :no_token), do: put_resp_header(conn, @header, "Bearer")

  def put_challenge(conn, :invalid_token),
    do: put_resp_header(conn, @header, ~s(Bearer error="invalid_token"))
end
