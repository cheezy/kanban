defmodule Kanban.OIDCTestHelpers do
  @moduledoc """
  A stub OpenID Connect provider for tests, served through the `Req.Test`
  stub the test environment routes `Kanban.SSO.OIDC` requests to.

      jwk = OIDCTestHelpers.signing_key()
      OIDCTestHelpers.stub_idp(jwk, fn _form -> OIDCTestHelpers.claims(nonce: nonce) end)

  The signing key is an RSA key generated for the test; tokens are signed
  with it, and the JWKS endpoint serves its public half.
  """

  alias Kanban.SSOFixtures

  @kid "test-key"

  @doc "A fresh RS256 signing key."
  def signing_key do
    {:rsa, 2048}
    |> JOSE.JWK.generate_key()
    |> JOSE.JWK.merge(%{"kid" => @kid, "use" => "sig"})
  end

  @doc "The public JWKS document for `jwk`."
  def jwks(jwk) do
    {_fields, public} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    %{"keys" => [public]}
  end

  @doc "A discovery document for `issuer`."
  def discovery(issuer \\ SSOFixtures.issuer(), overrides \\ %{}) do
    Map.merge(
      %{
        "issuer" => issuer,
        "authorization_endpoint" => "https://idp.example.com/authorize",
        "token_endpoint" => "https://idp.example.com/token",
        "jwks_uri" => "https://idp.example.com/jwks",
        "response_types_supported" => ["code"],
        "subject_types_supported" => ["public"],
        "id_token_signing_alg_values_supported" => ["RS256"],
        "token_endpoint_auth_methods_supported" => ["client_secret_basic"]
      },
      overrides
    )
  end

  @doc "Valid id_token claims for the fixture connection, overridable."
  def claims(overrides \\ []) do
    now = System.system_time(:second)

    Map.merge(
      %{
        "iss" => SSOFixtures.issuer(),
        "aud" => "stride-client",
        "sub" => "subject-#{System.unique_integer([:positive])}",
        "email" => "person#{System.unique_integer([:positive])}@example.com",
        "email_verified" => true,
        "name" => "Pat Person",
        "iat" => now,
        "exp" => now + 300
      },
      Map.new(overrides, fn {key, value} -> {to_string(key), value} end)
    )
  end

  @doc "Signs `claims` with `jwk` (RS256 by default) into a compact JWT."
  def sign(jwk, claims, alg \\ "RS256") do
    {_jws, token} =
      jwk
      |> JOSE.JWT.sign(%{"alg" => alg, "kid" => @kid}, claims)
      |> JOSE.JWS.compact()

    token
  end

  @doc "An unsigned (`alg: none`) token, built by hand."
  def unsigned(claims) do
    encode = fn map -> map |> Jason.encode!() |> Base.url_encode64(padding: false) end
    encode.(%{"alg" => "none", "typ" => "JWT"}) <> "." <> encode.(claims) <> "."
  end

  @doc """
  Stubs the provider. `token_fun` receives the decoded token request form and
  returns either claims to sign, `{:raw, id_token}`, or `{:status, code}`.
  Options: `:discovery` (a document) and `:jwk`.
  """
  def stub_idp(jwk, token_fun, opts \\ []) do
    discovery = Keyword.get(opts, :discovery, discovery())
    test_pid = self()

    Req.Test.stub(Kanban.SSO.OIDC, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/.well-known/openid-configuration"} ->
          Req.Test.json(conn, discovery)

        {"GET", "/jwks"} ->
          Req.Test.json(conn, jwks(jwk))

        {"POST", "/token"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          form = URI.decode_query(body)
          send(test_pid, {:token_request, form, Plug.Conn.get_req_header(conn, "authorization")})
          respond_token(conn, jwk, token_fun.(form))
      end
    end)
  end

  defp respond_token(conn, _jwk, {:status, status}),
    do: conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"error" => "invalid_grant"})

  defp respond_token(conn, _jwk, {:raw, id_token}), do: token_json(conn, id_token)

  defp respond_token(conn, jwk, claims) when is_map(claims),
    do: token_json(conn, sign(jwk, claims))

  defp token_json(conn, id_token) do
    Req.Test.json(conn, %{
      "id_token" => id_token,
      "token_type" => "Bearer",
      "access_token" => "at"
    })
  end
end
