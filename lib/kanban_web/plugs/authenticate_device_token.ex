defmodule KanbanWeb.Plugs.AuthenticateDeviceToken do
  @moduledoc """
  Authenticates person-API requests (`/api/me/*`) with a device access token
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.1, §9.2).

  The plug reads `Authorization: Bearer <token>` and looks the token up by its
  hash through `Kanban.Devices.fetch_by_access_token/2`, which refuses an
  unknown, expired or non-access token, a revoked device and a disabled user
  with one error. On success it assigns:

    * `:current_scope` — the same `Kanban.Accounts.Scope` the web builds:
      `Scope.for_user/1` with the user's Organization membership, so every
      `/api/me/*` route calls the same scope-first context functions as the
      LiveViews;
    * `:current_device` — the device the token belongs to, with
      `last_seen_at` moved to now (`Kanban.Devices.touch_last_seen/2`).

  It never assigns `:current_user` or `:api_token`, which agent code keys on.

  ## A device revoked while its request is in flight

  The token is checked once, before the action runs, so a device can be
  revoked, or its user disabled, while the action builds its response. For a
  `GET` or `HEAD` the plug checks the device again just before a successful
  response is sent, and a device that is no longer signed in gets the same
  `401 {"error": "Invalid access token"}` as its token would, never the data.
  Writes are not re-checked here, so a write that committed keeps its answer.
  Each write that changes anything re-checks the device under its own row
  lock first (`Kanban.Devices.CurrentDevice`, `Kanban.Devices.Revocation`,
  `Kanban.Reviews.DecisionChecks`), so a revoked device changes nothing. An
  approval challenge issued to a device revoked meanwhile can never be used,
  because the approval re-checks the device.

  ## Tokens that never cross

  An agent API token is refused here, and a device token is refused on every
  agent route by `KanbanWeb.Plugs.AuthenticateApiToken`. Both hold by
  construction: the two kinds of token live in different tables, and each plug
  looks up only its own, so a token of the other kind is simply unknown. A
  phone never becomes an agent, and an agent never acts as a person.

  ## Failures

  Every invalid token answers the same `401 {"error": "Invalid access
  token"}`, whatever the cause, so the response never says whether a string
  was ever a real token; the app answers it by refreshing. A missing or
  non-Bearer header answers `401 {"error": "Missing or invalid Authorization
  header"}`. Every `401`, the in-flight refusal below included, carries the
  `www-authenticate` challenge from `KanbanWeb.Plugs.BearerChallenge`:
  `Bearer` for a missing or non-Bearer header, and
  `Bearer error="invalid_token"` for a refused token, whatever the cause.
  Failed authentications count toward the same per-IP limit as
  agent tokens, which answers `429` with `retry-after`, and emit
  `[:kanban, :api, :auth_failed]` with reason `missing_token`,
  `device_token_invalid` or `rate_limited`. The header and the token are never
  logged.

  One failure is not counted toward that limit (decided 2026-11-19): a
  device access token Stride recognises, on a device still signed in, that
  has only passed its `expires_at` (`Kanban.Devices.authenticate_access_token/2`).
  Every app sends one each hour before it refreshes, and many phones behind
  one address would otherwise lock that address's agents out. It answers the
  same `401 {"error": "Invalid access token"}` with the same headers, writes
  the same audit row and emits the same telemetry reason, after the same one
  read, so the response still never says the token was real. An unknown or
  malformed token is counted.

  ## Caching

  Every response here, a refusal included, is `cache-control: private,
  no-store`, set by `KanbanWeb.Plugs.DeviceApiCacheControl`, which runs
  before this plug in the `:device_api` pipeline.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Kanban.Accounts.Scope
  alias Kanban.Devices
  alias Kanban.Organizations
  alias Kanban.RateLimit
  alias KanbanWeb.Plugs.BearerChallenge

  def init(opts), do: opts

  def call(conn, _opts) do
    # Throttle a token-guessing flood by source IP before touching the DB.
    # Only failed authentications are counted.
    case RateLimit.peek(:api_token, ip: conn.remote_ip) do
      {:error, {:rate_limited, retry_after_ms}} -> halt_rate_limited(conn, retry_after_ms)
      :ok -> authenticate(conn)
    end
  end

  defp authenticate(conn) do
    with {:ok, token} <- extract_token(conn),
         {:ok, device} <- Devices.authenticate_access_token(token) do
      conn
      |> assign(:current_scope, scope_for(device.user))
      |> assign(:current_device, Devices.touch_last_seen(device))
      |> recheck_before_read_is_sent(device)
    else
      {:error, reason} -> halt_failed(conn, reason)
    end
  end

  defp halt_failed(conn, :missing_token), do: halt_missing_token(conn)
  defp halt_failed(conn, :expired_token), do: halt_invalid_token(conn, :not_counted)
  defp halt_failed(conn, :invalid_token), do: halt_invalid_token(conn, :counted)

  # A read builds its response from data the device was allowed to see when
  # the token was checked. Checking the device again just before the response
  # goes out refuses a read whose device was revoked, or whose user was
  # disabled, while it was being built, so a revoked device never receives
  # data read after its revocation. Only successful GET and HEAD responses
  # are rechecked: a write re-checks the device under its own lock, and
  # turning a write that committed into a 401 would tell the app it did not
  # happen.
  defp recheck_before_read_is_sent(%Plug.Conn{method: method} = conn, device)
       when method in ["GET", "HEAD"] do
    register_before_send(conn, fn conn ->
      if conn.status in 200..299 and not Devices.Activity.signed_in?(device) do
        refuse_revoked_in_flight(conn)
      else
        conn
      end
    end)
  end

  defp recheck_before_read_is_sent(conn, _device), do: conn

  # The body a revoked device's token gets, so the app handles both the same
  # way. Headers the action set for the refused body are dropped with it; with
  # the etag gone, KanbanWeb.Plugs.DeviceApiCacheControl, whose callback runs
  # after this one, sends the refusal as no-store.
  defp refuse_revoked_in_flight(conn) do
    conn
    |> delete_resp_header("etag")
    |> put_resp_header("cache-control", "private, no-store")
    |> BearerChallenge.put_challenge(:invalid_token)
    |> put_resp_content_type("application/json")
    |> resp(:unauthorized, Jason.encode!(%{error: "Invalid access token"}))
  end

  @doc """
  The scope a device's `user` acts with: the one `KanbanWeb.UserAuth` builds
  for the web, Organization membership included. `KanbanWeb.UserSocket`
  assigns the same scope.
  """
  @spec scope_for(Kanban.Accounts.User.t()) :: Scope.t()
  def scope_for(user) do
    user
    |> Scope.for_user()
    |> Scope.put_organization_membership(Organizations.get_membership(user))
  end

  # The auth scheme is case-insensitive (RFC 7235 §2.1), so `bearer` and
  # `BEARER` are read as `Bearer`.
  defp extract_token(conn) do
    with [header] <- get_req_header(conn, "authorization"),
         [scheme, token] <- String.split(header, " ", parts: 2),
         "bearer" <- String.downcase(scheme) do
      {:ok, String.trim(token)}
    else
      _ -> {:error, :missing_token}
    end
  end

  # A request-format signal, not token-state disclosure, so it keeps its own
  # body as in AuthenticateApiToken.
  defp halt_missing_token(conn) do
    record_failure(conn, :missing_token)
    emit_auth_failed_telemetry(conn, "missing_token")

    conn
    |> BearerChallenge.put_challenge(:no_token)
    |> put_status(:unauthorized)
    |> json(%{error: "Missing or invalid Authorization header"})
    |> halt()
  end

  # A recognised token that has only expired (:not_counted) is what every app
  # sends once an hour before it refreshes, so it is left out of the per-IP
  # failure count that agent tokens share; phones behind one office address
  # would otherwise lock that address's agents out. It still gets the same
  # 401, audit row and telemetry reason as any invalid token, so the response
  # does not say the token was ever real. An unknown or malformed token, or
  # one of a revoked device or a disabled user, is counted.
  defp halt_invalid_token(conn, counting) do
    if counting == :counted, do: count_failure(conn)
    audit_failure(conn, :device_token_invalid)
    emit_auth_failed_telemetry(conn, "device_token_invalid")

    conn
    |> BearerChallenge.put_challenge(:invalid_token)
    |> put_status(:unauthorized)
    |> json(%{error: "Invalid access token"})
    |> halt()
  end

  defp record_failure(conn, reason) do
    count_failure(conn)
    audit_failure(conn, reason)
  end

  defp count_failure(conn), do: RateLimit.record_failure(:api_token, ip: conn.remote_ip)

  defp audit_failure(conn, reason),
    do: Kanban.AuditLog.event(:api_token_auth_failed, ip: conn.remote_ip, reason: reason)

  defp halt_rate_limited(conn, retry_after_ms) do
    emit_auth_failed_telemetry(conn, "rate_limited")

    conn
    |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms, 1000) + 1))
    |> put_status(:too_many_requests)
    |> json(%{error: "Too many requests"})
    |> halt()
  end

  defp emit_auth_failed_telemetry(conn, reason) do
    Kanban.Telemetry.emit(
      [:kanban, :api, :auth_failed],
      %{count: 1},
      %{reason: reason, path: conn.request_path, method: conn.method}
    )
  end
end
