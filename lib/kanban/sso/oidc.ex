defmodule Kanban.SSO.OIDC do
  @moduledoc """
  The OpenID Connect protocol steps for `Kanban.SSO.OIDCLogin`: discovery,
  the authorization URL with PKCE, state and nonce, the code exchange, and
  id_token validation. It reads no database rows.

  Discovery, JWKS and token requests go through Req with `redirect: false`
  and `retry: false`, and every URL is checked by `Kanban.SSO.pinned_request/1`
  first, which also pins the request to the address the check approved. The
  provider is chosen by an org-admin and any visitor can start a sign-in, so
  each request is also bounded: a 5 second connect timeout, a response body of
  at most #{1_048_576} bytes (a larger one is refused, not cut), and a
  deadline for the whole request, 10 seconds unless
  `config :kanban, Kanban.SSO.OIDC, deadline_ms: ...` says otherwise, so a
  provider that answers a byte at a time cannot hold a sign-in open.
  `config :kanban, Kanban.SSO.OIDC, req_options: [...]` is merged into every
  request; the test environment routes them to a `Req.Test` stub, so no test
  touches the network.

  id_token validation is delegated to `oidcc` (the EEF's OpenID-certified
  library): signature against the provider's JWKS, `iss`, `aud`, `azp`,
  `exp`, `nbf` and `nonce`. The signing algorithms it accepts are narrowed to
  asymmetric ones first, so `none` and HMAC tokens signed with the client
  secret are refused, and encrypted id_tokens are refused too. The allowed
  clock skew is the `:oidcc` application's `max_clock_skew`.
  """

  alias Kanban.SSO
  alias Kanban.SSO.SSOConnection

  @scope "openid email profile"
  @allowed_algs ~w(RS256 RS384 RS512 PS256 PS384 PS512 ES256 ES384 ES512 EdDSA)
  @max_body 1_048_576
  @default_deadline_ms 10_000

  @doc "The largest provider response body read, in bytes."
  @spec max_body() :: pos_integer()
  def max_body, do: @max_body

  @type provider :: %{config: Oidcc.ProviderConfiguration.t(), jwks: JOSE.JWK.t()}

  @doc """
  A new sign-in flow for the connection with `connection_id`: random `state`,
  `nonce` and PKCE `verifier` (32 random bytes each, base64url), and the time
  it was issued. Stored in the browser session until the callback.
  """
  @spec new_flow(integer()) :: map()
  def new_flow(connection_id) when is_integer(connection_id) do
    %{
      "connection_id" => connection_id,
      "state" => random(),
      "nonce" => random(),
      "verifier" => random(),
      "issued_at" => System.system_time(:second)
    }
  end

  defp random, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc """
  Fetches the provider's discovery document and JWKS. The document's issuer
  must equal the connection's issuer exactly.
  """
  @spec fetch_provider(SSOConnection.t()) :: {:ok, provider()} | {:error, atom()}
  def fetch_provider(%SSOConnection{issuer: issuer}) do
    with {:ok, config} <- fetch_configuration(issuer),
         {:ok, jwks} <- fetch_jwks(config) do
      {:ok, %{config: config, jwks: jwks}}
    end
  end

  defp fetch_configuration(issuer) do
    discovery_url = String.trim_trailing(issuer, "/") <> "/.well-known/openid-configuration"

    with {:ok, document} <- get_json(discovery_url),
         {:ok, config} <- decode_configuration(document),
         :ok <- same_issuer(config, issuer) do
      restrict_algorithms(config)
    end
  end

  defp fetch_jwks(config) do
    with {:ok, jwks_document} <- get_json(config.jwks_uri) do
      decode_jwks(jwks_document)
    end
  end

  # scopes_supported is only RECOMMENDED by OpenID Connect Discovery, but oidcc
  # requires it; a provider that leaves it out still supports openid.
  defp decode_configuration(document) do
    quirks = %{allow_unsafe_http: SSO.allow_private_issuers?()}
    document = Map.put_new(document, "scopes_supported", ["openid"])

    case Oidcc.ProviderConfiguration.decode_configuration(document, %{quirks: quirks}) do
      {:ok, config} -> {:ok, config}
      {:error, _reason} -> {:error, :invalid_discovery}
    end
  rescue
    _error -> {:error, :invalid_discovery}
  end

  defp same_issuer(%{issuer: issuer}, issuer), do: :ok
  defp same_issuer(_config, _issuer), do: {:error, :issuer_mismatch}

  defp restrict_algorithms(config) do
    case config.id_token_signing_alg_values_supported
         |> List.wrap()
         |> Enum.filter(&(&1 in @allowed_algs)) do
      [] ->
        {:error, :unsupported_algorithms}

      algs ->
        {:ok,
         %{
           config
           | id_token_signing_alg_values_supported: algs,
             id_token_encryption_alg_values_supported: :undefined,
             id_token_encryption_enc_values_supported: :undefined
         }}
    end
  end

  defp decode_jwks(%{"keys" => keys} = document) when is_list(keys) do
    {:ok, JOSE.JWK.from_map(document)}
  rescue
    _error -> {:error, :invalid_jwks}
  end

  defp decode_jwks(_document), do: {:error, :invalid_jwks}

  @doc """
  The authorization request URL: authorization code with PKCE (S256), the
  flow's `state` and `nonce`, and the `openid email profile` scope.
  """
  @spec authorize_url(Oidcc.ProviderConfiguration.t(), SSOConnection.t(), String.t(), map()) ::
          String.t()
  def authorize_url(config, %SSOConnection{} = connection, redirect_uri, flow) do
    uri = URI.parse(config.authorization_endpoint)
    existing = URI.decode_query(uri.query || "")

    query =
      Map.merge(existing, %{
        "response_type" => "code",
        "client_id" => connection.client_id,
        "redirect_uri" => redirect_uri,
        "scope" => @scope,
        "state" => flow["state"],
        "nonce" => flow["nonce"],
        "code_challenge" => code_challenge(flow["verifier"]),
        "code_challenge_method" => "S256"
      })

    URI.to_string(%{uri | query: URI.encode_query(query)})
  end

  @doc "The S256 PKCE challenge for `verifier`."
  @spec code_challenge(String.t()) :: String.t()
  def code_challenge(verifier),
    do: :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)

  @doc """
  Exchanges the authorization code (with the PKCE verifier) at the token
  endpoint and returns the id_token. Authenticates with `client_secret_basic`
  unless the provider lists only `client_secret_post`.
  """
  @spec exchange_code(
          Oidcc.ProviderConfiguration.t(),
          SSOConnection.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, String.t()} | {:error, atom()}
  def exchange_code(config, %SSOConnection{} = connection, code, verifier, redirect_uri) do
    form = [
      grant_type: "authorization_code",
      code: code,
      redirect_uri: redirect_uri,
      code_verifier: verifier,
      client_id: connection.client_id
    ]

    with {:ok, {form, headers}} <- client_auth(config, connection, form) do
      post_token_request(config.token_endpoint, form, headers)
    end
  end

  defp post_token_request(token_endpoint, form, headers) do
    with {:ok, pinned} <- SSO.pinned_request(token_endpoint),
         {:ok, %Req.Response{status: 200, body: body}} <-
           request(:post, pinned, form: form, headers: headers),
         {:ok, %{"id_token" => id_token}} when is_binary(id_token) <- json_body(body) do
      {:ok, id_token}
    else
      _failed -> {:error, :token_exchange_failed}
    end
  end

  defp client_auth(config, connection, form) do
    methods =
      case config.token_endpoint_auth_methods_supported do
        methods when is_list(methods) -> methods
        _absent -> ["client_secret_basic"]
      end

    cond do
      "client_secret_basic" in methods ->
        credentials =
          URI.encode_www_form(connection.client_id) <>
            ":" <> URI.encode_www_form(connection.client_secret)

        {:ok, {form, [{"authorization", "Basic " <> Base.encode64(credentials)}]}}

      "client_secret_post" in methods ->
        {:ok, {form ++ [client_secret: connection.client_secret], []}}

      true ->
        {:error, :unsupported_client_auth}
    end
  end

  @doc """
  Validates the id_token against the provider and the flow's nonce. Returns
  its claims, `{:error, :token_expired}` or `{:error, :invalid_token}`.
  """
  @spec validate_id_token(provider(), SSOConnection.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :token_expired | :invalid_token}
  def validate_id_token(
        %{config: config, jwks: jwks},
        %SSOConnection{} = connection,
        id_token,
        nonce
      )
      when is_binary(id_token) and is_binary(nonce) do
    context =
      Oidcc.ClientContext.from_manual(
        config,
        jwks,
        connection.client_id,
        connection.client_secret
      )

    case Oidcc.Token.validate_id_token(id_token, context, nonce) do
      {:ok, claims} when is_map(claims) -> {:ok, claims}
      {:error, :token_expired} -> {:error, :token_expired}
      {:error, _reason} -> {:error, :invalid_token}
    end
  rescue
    _error -> {:error, :invalid_token}
  catch
    _kind, _reason -> {:error, :invalid_token}
  end

  defp get_json(url) do
    with {:ok, pinned} <- SSO.pinned_request(url),
         {:ok, %Req.Response{status: 200, body: body}} <- request(:get, pinned, []),
         {:ok, document} <- json_body(body) do
      {:ok, document}
    else
      {:error, :unsafe_url} -> {:error, :unsafe_url}
      _failed -> {:error, :provider_unreachable}
    end
  end

  defp json_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, document} when is_map(document) -> {:ok, document}
      _invalid -> :error
    end
  end

  defp json_body(_body), do: :error

  # Runs the request in its own process so the deadline covers all of it:
  # receive_timeout only bounds the wait for each packet.
  defp request(method, pinned, options) do
    task =
      Task.Supervisor.async_nolink(Kanban.TaskSupervisor, fn ->
        send_request(method, pinned, options)
      end)

    case Task.yield(task, deadline_ms()) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _timed_out_or_crashed -> {:error, :request_failed}
    end
  end

  # `pinned` comes from SSO.pinned_request/1: the URL rewritten to the approved
  # address, plus the host header and TLS host name that go with it. The body
  # is collected by collect/2 and decoded by the caller.
  defp send_request(method, pinned, options) do
    headers = Keyword.get(pinned, :headers, []) ++ Keyword.get(options, :headers, [])
    connect_options = Keyword.put(Keyword.get(pinned, :connect_options, []), :timeout, 5_000)

    [
      method: method,
      redirect: false,
      retry: false,
      receive_timeout: 5_000,
      decode_body: false,
      into: &collect/2
    ]
    |> Keyword.merge(pinned)
    |> Keyword.merge(options)
    |> Keyword.put(:headers, headers)
    |> Keyword.put(:connect_options, connect_options)
    |> Keyword.merge(configured(:req_options, []))
    |> Req.request()
    |> refuse_oversized()
  rescue
    _error -> {:error, :request_failed}
  end

  # Req's `into:` callback: stops reading once the body passes @max_body.
  defp collect({:data, data}, {request, response}) do
    body = IO.iodata_to_binary(response.body) <> data

    if byte_size(body) > @max_body,
      do: {:halt, {request, %{response | body: :too_large}}},
      else: {:cont, {request, %{response | body: body}}}
  end

  defp refuse_oversized({:ok, %Req.Response{body: :too_large}}), do: {:error, :response_too_large}
  defp refuse_oversized(result), do: result

  defp deadline_ms do
    case configured(:deadline_ms, @default_deadline_ms) do
      deadline when is_integer(deadline) and deadline > 0 -> deadline
      _invalid -> @default_deadline_ms
    end
  end

  defp configured(key, default) do
    :kanban
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end
end
