defmodule KanbanWeb.OAuthTokenController do
  @moduledoc """
  The token half of device sign-in
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.1, §9.1, §9.2):

    * `POST /oauth/token` (RFC 6749 §4.1.3, §6) redeems an authorization
      code and PKCE verifier for a new device and its first token pair
      (`grant_type=authorization_code`), or rotates a refresh token
      (`grant_type=refresh_token`).
    * `POST /oauth/revoke` (RFC 7009) signs a device out by its refresh
      token.

  Both sit in the `:oauth` pipeline, which authenticates nothing: what
  proves the caller is the code and verifier, or the refresh token, and
  each travels only in the request body, form-encoded or JSON. Both actions
  read `conn.body_params` alone, so a parameter in the query string is never
  used: a credential put in a URL, where proxy and access logs keep it,
  counts as missing (RFC 6749 §3.2, RFC 7009 §2.1). A bearer header is never
  read, on either route.

  Every refusal is RFC 6749 §5.2's `{"error", "error_description"}` with a
  400 status (`invalid_request`, `invalid_client`, `invalid_grant`,
  `unsupported_grant_type`), or a 429 `rate_limited` with `retry-after`. A
  description is fixed text, or names fields, and never echoes a value
  sent. A failed rotation and a detected reuse answer the same
  `invalid_grant`, and no failure ever carries a token. Every response is
  `cache-control: no-store` (RFC 6749 §5.1): `KanbanWeb.Plugs.Parsers` sets
  it for both paths before the body is parsed, so the errors raised before
  this controller runs carry it too, and `no_store/2` here sets it again.

  `POST /oauth/revoke` answers 200 for any well-formed request, whether or
  not the token named a live device (RFC 7009 §2.2), so it cannot be used to
  probe tokens.
  """
  use KanbanWeb, :controller

  alias Kanban.Devices
  alias Kanban.Devices.Clients
  alias Kanban.RateLimit

  @detail_params ~w(platform device_class model os_version app_version locale time_zone approval_public_key)
  @grant_types ~w(authorization_code refresh_token)

  @descriptions %{
    invalid_request: "The request is missing a required parameter or has an invalid one.",
    invalid_client: "The client is not a Stride app.",
    invalid_grant: "The authorization code or refresh token is invalid, expired or already used.",
    unsupported_grant_type: "Only authorization_code and refresh_token are supported."
  }

  plug :no_store

  @doc "`POST /oauth/token`."
  def token(conn, _params) do
    params = body_params(conn)

    with :ok <- RateLimit.check(:oauth_token, ip: conn.remote_ip),
         {:ok, grant_type} <- grant_type(params),
         :ok <- client(params) do
      grant(conn, grant_type, params)
    else
      {:error, reason} -> refuse(conn, reason)
    end
  end

  @doc "`POST /oauth/revoke`."
  def revoke(conn, _params) do
    params = body_params(conn)

    with :ok <- RateLimit.check(:oauth_revoke, ip: conn.remote_ip),
         {:ok, token} <- required(params, "token"),
         :ok <- client(params),
         :ok <- token_rate_limit(token) do
      _revoked_or_unknown = Devices.revoke_by_refresh_token(token, now(), ip: conn.remote_ip)
      json(conn, %{})
    else
      {:error, reason} -> refuse(conn, reason)
    end
  end

  defp grant(conn, "authorization_code", params) do
    case code_grant(params) do
      {:ok, grant} ->
        at = now()
        details = Map.take(params, @detail_params)

        grant
        |> Devices.exchange_authorization_code(details, at, ip: conn.remote_ip)
        |> respond(conn, at)

      {:error, reason} ->
        refuse(conn, reason)
    end
  end

  defp grant(conn, "refresh_token", params) do
    with {:ok, refresh_token} <- required(params, "refresh_token"),
         :ok <- token_rate_limit(refresh_token) do
      at = now()

      refresh_token
      |> Devices.rotate_refresh_token(at, ip: conn.remote_ip, client_id: params["client_id"])
      |> respond(conn, at)
    else
      {:error, reason} -> refuse(conn, reason)
    end
  end

  defp code_grant(params) do
    with {:ok, code} <- required(params, "code"),
         {:ok, verifier} <- required(params, "code_verifier"),
         {:ok, redirect_uri} <- required(params, "redirect_uri") do
      {:ok,
       %{
         code: code,
         client_id: params["client_id"],
         redirect_uri: redirect_uri,
         code_verifier: verifier
       }}
    end
  end

  defp respond({:ok, issued}, conn, at) do
    json(conn, %{
      access_token: issued.access_token,
      token_type: "Bearer",
      expires_in: DateTime.diff(issued.access_token_expires_at, at),
      refresh_token: issued.refresh_token
    })
  end

  defp respond({:error, %Ecto.Changeset{} = changeset}, conn, _at),
    do: refuse(conn, {:invalid_request, invalid_details(changeset)})

  defp respond({:error, _invalid_grant_or_token}, conn, _at), do: refuse(conn, :invalid_grant)

  defp grant_type(%{"grant_type" => grant_type}) when grant_type in @grant_types,
    do: {:ok, grant_type}

  defp grant_type(%{"grant_type" => grant_type}) when is_binary(grant_type) and grant_type != "",
    do: {:error, :unsupported_grant_type}

  defp grant_type(_params), do: {:error, :invalid_request}

  defp client(params) do
    with {:ok, client_id} <- required(params, "client_id") do
      if Clients.valid_client?(client_id), do: :ok, else: {:error, :invalid_client}
    end
  end

  # Plug.Parsers leaves the body unfetched for a content type it passes
  # through (text/plain, say); such a body carries no parameters.
  defp body_params(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}), do: %{}
  defp body_params(%Plug.Conn{body_params: params}), do: params

  # A value must be a non-empty string: a list or map (`code[]=…`) is as
  # invalid as a missing one.
  defp required(params, key) do
    case params[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing_or_not_text -> {:error, :invalid_request}
    end
  end

  # Every presented refresh token is counted, keyed on a short digest of the
  # token itself and never on whether it names a device, so an unknown, a
  # revoked and a live token reach the limit after the same number of
  # attempts and get the same 429: the limit cannot tell a guesser which
  # tokens were ever real. No IP is passed, so one token is limited however
  # many addresses present it; the :oauth_token and :oauth_revoke ceilings
  # count per IP. Nothing is looked up before the check. The token itself
  # never reaches the rate limiter.
  defp token_rate_limit(refresh_token),
    do: RateLimit.check(:oauth_device, identity: token_identity(refresh_token))

  defp token_identity(refresh_token) do
    digest = :crypto.hash(:sha256, refresh_token) |> Base.encode16(case: :lower)
    "token:" <> binary_part(digest, 0, 16)
  end

  # Field names only, never the values sent.
  defp invalid_details(changeset) do
    fields = changeset.errors |> Keyword.keys() |> Enum.uniq() |> Enum.sort() |> Enum.join(", ")
    "The device details are missing or invalid: #{fields}."
  end

  defp refuse(conn, {:rate_limited, retry_after_ms}) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms, 1000) + 1))
    |> put_status(:too_many_requests)
    |> json(%{error: "rate_limited", error_description: "Too many requests. Try again later."})
  end

  defp refuse(conn, {:invalid_request, description}),
    do: error(conn, :invalid_request, description)

  defp refuse(conn, reason), do: error(conn, reason, Map.fetch!(@descriptions, reason))

  defp error(conn, reason, description) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: Atom.to_string(reason), error_description: description})
  end

  defp no_store(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
