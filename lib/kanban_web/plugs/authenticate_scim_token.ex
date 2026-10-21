defmodule KanbanWeb.Plugs.AuthenticateScimToken do
  @moduledoc """
  Authenticates `/scim/v2` requests with an Organization-scoped SCIM token
  (W2247), sent as `Authorization: Bearer <token>`, and assigns it as
  `:scim_token`. Every SCIM query is scoped to that token's Organization.

  A missing, unknown or revoked token gets a `401` with one identical SCIM
  error body, so the response never says whether a string was ever a token,
  and is audited as `:scim_auth_failed` with only the reason. Failures are
  rate limited (`Kanban.RateLimit`, surface `:scim`): a flood is refused with
  `429` and `retry-after` before the token is looked up. The token value is
  never logged or audited.
  """

  import Plug.Conn

  alias Kanban.RateLimit
  alias Kanban.SCIM
  alias KanbanWeb.SCIM.Response

  def init(opts), do: opts

  def call(conn, _opts) do
    presented = bearer_token(conn)
    limit_opts = [ip: conn.remote_ip, identity: rate_identity(presented)]

    case RateLimit.peek(:scim, limit_opts) do
      {:error, {:rate_limited, retry_after_ms}} -> halt_rate_limited(conn, retry_after_ms)
      :ok -> authenticate(conn, presented, limit_opts)
    end
  end

  defp authenticate(conn, presented, limit_opts) do
    case authenticate_token(presented) do
      {:ok, token} ->
        assign(conn, :scim_token, token)

      {:error, reason} ->
        RateLimit.record_failure(:scim, limit_opts)
        Kanban.AuditLog.event(:scim_auth_failed, ip: conn.remote_ip, reason: reason)

        conn
        |> put_resp_header("www-authenticate", ~s(Bearer realm="SCIM"))
        |> Response.send_error(401, nil, "A valid SCIM bearer token is required.")
        |> halt()
    end
  end

  defp authenticate_token(nil), do: {:error, :missing_token}
  defp authenticate_token(presented), do: SCIM.authenticate(presented)

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      [header] -> parse_bearer(header)
      _missing_or_repeated -> nil
    end
  end

  defp parse_bearer(header) do
    case String.split(header, " ", parts: 2) do
      [scheme, token] ->
        if String.downcase(scheme) == "bearer", do: non_blank(String.trim(token))

      _other ->
        nil
    end
  end

  defp non_blank(""), do: nil
  defp non_blank(token), do: token

  # A short digest of the presented token keys its failures, so one tenant
  # retrying a revoked token does not lock out others behind the same
  # provider egress IP. The token itself never reaches the rate limiter.
  defp rate_identity(nil), do: "missing"

  defp rate_identity(presented) do
    "token:" <>
      (:crypto.hash(:sha256, presented) |> Base.encode16(case: :lower) |> binary_part(0, 16))
  end

  defp halt_rate_limited(conn, retry_after_ms) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms, 1000) + 1))
    |> Response.send_error(429, nil, "Too many requests.")
    |> halt()
  end
end
