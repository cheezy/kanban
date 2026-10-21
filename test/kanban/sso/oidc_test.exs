defmodule Kanban.SSO.OIDCTest do
  use Kanban.DataCase, async: true

  import Kanban.OrganizationsFixtures
  import Kanban.SSOFixtures

  alias Kanban.OIDCTestHelpers
  alias Kanban.SSO.OIDC

  setup_all do
    %{jwk: OIDCTestHelpers.signing_key()}
  end

  setup do
    %{connection: oidc_connection_fixture(organization_fixture())}
  end

  defp provider(connection, jwk, opts \\ []) do
    OIDCTestHelpers.stub_idp(jwk, fn _form -> %{} end, opts)
    OIDC.fetch_provider(connection)
  end

  describe "new_flow/1" do
    test "carries random state, nonce and a PKCE-valid verifier" do
      flow = OIDC.new_flow(7)
      other = OIDC.new_flow(7)

      assert flow["connection_id"] == 7
      assert byte_size(flow["verifier"]) == 43
      assert flow["state"] != other["state"]
      assert flow["nonce"] != flow["state"]
      assert is_integer(flow["issued_at"])
    end
  end

  describe "fetch_provider/1" do
    test "loads the discovery document and JWKS", %{connection: connection, jwk: jwk} do
      assert {:ok, %{config: config, jwks: %JOSE.JWK{}}} = provider(connection, jwk)
      assert config.issuer == issuer()
      assert config.id_token_signing_alg_values_supported == ["RS256"]
    end

    test "sends each request to the checked address and keeps the host name", %{
      connection: connection,
      jwk: jwk
    } do
      test_pid = self()

      Req.Test.stub(OIDC, fn conn ->
        send(
          test_pid,
          {:request, conn.request_path, conn.host, Plug.Conn.get_req_header(conn, "host")}
        )

        case conn.request_path do
          "/.well-known/openid-configuration" -> Req.Test.json(conn, OIDCTestHelpers.discovery())
          "/jwks" -> Req.Test.json(conn, OIDCTestHelpers.jwks(jwk))
        end
      end)

      assert {:ok, _provider} = OIDC.fetch_provider(connection)

      assert_received {:request, "/.well-known/openid-configuration", "93.184.216.34",
                       ["idp.example.com"]}

      assert_received {:request, "/jwks", "93.184.216.34", ["idp.example.com"]}
    end

    test "refuses a document whose issuer differs from the connection's", %{
      connection: connection,
      jwk: jwk
    } do
      assert {:error, :issuer_mismatch} =
               provider(connection, jwk,
                 discovery: OIDCTestHelpers.discovery("https://evil.example.com")
               )
    end

    test "refuses a provider offering only symmetric or none algorithms", %{
      connection: connection,
      jwk: jwk
    } do
      discovery =
        OIDCTestHelpers.discovery(issuer(), %{
          "id_token_signing_alg_values_supported" => ["HS256", "none"]
        })

      assert {:error, :unsupported_algorithms} = provider(connection, jwk, discovery: discovery)
    end

    test "refuses an invalid discovery document", %{connection: connection, jwk: jwk} do
      assert {:error, :invalid_discovery} =
               provider(connection, jwk, discovery: %{"issuer" => issuer()})
    end

    test "reports an unreachable provider", %{connection: connection} do
      Req.Test.stub(Kanban.SSO.OIDC, &Req.Test.transport_error(&1, :timeout))
      assert {:error, :provider_unreachable} = OIDC.fetch_provider(connection)

      Req.Test.stub(Kanban.SSO.OIDC, &Plug.Conn.send_resp(&1, 500, "oops"))
      assert {:error, :provider_unreachable} = OIDC.fetch_provider(connection)

      Req.Test.stub(Kanban.SSO.OIDC, &Plug.Conn.send_resp(&1, 200, "not json"))
      assert {:error, :provider_unreachable} = OIDC.fetch_provider(connection)
    end

    test "refuses a JWKS without keys", %{connection: connection} do
      Req.Test.stub(Kanban.SSO.OIDC, fn conn ->
        case conn.request_path do
          "/jwks" -> Req.Test.json(conn, %{"nope" => []})
          _discovery -> Req.Test.json(conn, OIDCTestHelpers.discovery())
        end
      end)

      assert {:error, :invalid_jwks} = OIDC.fetch_provider(connection)
    end

    test "never fetches a private address", %{jwk: jwk} do
      connection = oidc_connection_fixture(organization_fixture())
      OIDCTestHelpers.stub_idp(jwk, fn _form -> %{} end)

      private = %{connection | issuer: "https://internal.example.com"}
      assert {:error, :unsafe_url} = OIDC.fetch_provider(private)

      jwks_private =
        OIDCTestHelpers.discovery(issuer(), %{"jwks_uri" => "https://internal.example.com/jwks"})

      OIDCTestHelpers.stub_idp(jwk, fn _form -> %{} end, discovery: jwks_private)
      assert {:error, :unsafe_url} = OIDC.fetch_provider(connection)
    end
  end

  describe "authorize_url/4" do
    test "requests the code flow with PKCE S256, state and nonce", %{
      connection: connection,
      jwk: jwk
    } do
      {:ok, %{config: config}} = provider(connection, jwk)
      flow = OIDC.new_flow(connection.id)

      uri =
        config |> OIDC.authorize_url(connection, "https://stride.test/cb", flow) |> URI.parse()

      query = URI.decode_query(uri.query)

      assert uri.host == "idp.example.com"
      assert query["response_type"] == "code"
      assert query["client_id"] == "stride-client"
      assert query["redirect_uri"] == "https://stride.test/cb"
      assert query["scope"] == "openid email profile"
      assert query["state"] == flow["state"]
      assert query["nonce"] == flow["nonce"]
      assert query["code_challenge_method"] == "S256"
      assert query["code_challenge"] == OIDC.code_challenge(flow["verifier"])
      refute query["code_challenge"] == flow["verifier"]
    end
  end

  describe "exchange_code/5" do
    test "posts the code and verifier with client_secret_basic", %{
      connection: connection,
      jwk: jwk
    } do
      {:ok, %{config: config}} = provider(connection, jwk)
      OIDCTestHelpers.stub_idp(jwk, fn _form -> OIDCTestHelpers.claims() end)

      assert {:ok, id_token} =
               OIDC.exchange_code(config, connection, "the-code", "v", "https://cb")

      assert is_binary(id_token)

      assert_received {:token_request, form, ["Basic " <> credentials]}
      assert form["grant_type"] == "authorization_code"
      assert form["code"] == "the-code"
      assert form["code_verifier"] == "v"
      assert form["redirect_uri"] == "https://cb"
      refute Map.has_key?(form, "client_secret")
      assert Base.decode64!(credentials) == "stride-client:fixture-client-credential"
    end

    test "posts to the checked address of the token endpoint", %{connection: connection, jwk: jwk} do
      {:ok, %{config: config}} = provider(connection, jwk)
      test_pid = self()

      Req.Test.stub(OIDC, fn conn ->
        send(test_pid, {:token_host, conn.host, Plug.Conn.get_req_header(conn, "host")})
        Req.Test.json(conn, %{"id_token" => "a.b.c"})
      end)

      assert {:ok, "a.b.c"} = OIDC.exchange_code(config, connection, "c", "v", "https://cb")
      assert_received {:token_host, "93.184.216.34", ["idp.example.com"]}
    end

    test "uses client_secret_post when that is all the provider supports", %{
      connection: connection,
      jwk: jwk
    } do
      discovery =
        OIDCTestHelpers.discovery(issuer(), %{
          "token_endpoint_auth_methods_supported" => ["client_secret_post"]
        })

      {:ok, %{config: config}} = provider(connection, jwk, discovery: discovery)

      OIDCTestHelpers.stub_idp(jwk, fn _form -> OIDCTestHelpers.claims() end,
        discovery: discovery
      )

      assert {:ok, _id_token} = OIDC.exchange_code(config, connection, "c", "v", "https://cb")
      assert_received {:token_request, %{"client_secret" => "fixture-client-credential"}, []}
    end

    test "refuses a provider with no supported client authentication", %{
      connection: connection,
      jwk: jwk
    } do
      discovery =
        OIDCTestHelpers.discovery(issuer(), %{
          "token_endpoint_auth_methods_supported" => ["private_key_jwt"]
        })

      {:ok, %{config: config}} = provider(connection, jwk, discovery: discovery)

      assert {:error, :unsupported_client_auth} =
               OIDC.exchange_code(config, connection, "c", "v", "https://cb")
    end

    test "reports a failed exchange", %{connection: connection, jwk: jwk} do
      {:ok, %{config: config}} = provider(connection, jwk)
      OIDCTestHelpers.stub_idp(jwk, fn _form -> {:status, 400} end)

      assert {:error, :token_exchange_failed} =
               OIDC.exchange_code(config, connection, "c", "v", "https://cb")
    end
  end

  describe "validate_id_token/4" do
    setup %{connection: connection, jwk: jwk} do
      {:ok, provider} = provider(connection, jwk)
      %{provider: provider}
    end

    test "returns the claims of a valid token", %{provider: p, connection: c, jwk: jwk} do
      claims = OIDCTestHelpers.claims(nonce: "n1")

      assert {:ok, %{"sub" => sub}} =
               OIDC.validate_id_token(p, c, OIDCTestHelpers.sign(jwk, claims), "n1")

      assert sub == claims["sub"]
    end

    test "rejects a bad nonce", %{provider: p, connection: c, jwk: jwk} do
      token = OIDCTestHelpers.sign(jwk, OIDCTestHelpers.claims(nonce: "n1"))
      assert {:error, :invalid_token} = OIDC.validate_id_token(p, c, token, "other")
    end

    test "rejects a wrong audience", %{provider: p, connection: c, jwk: jwk} do
      token = OIDCTestHelpers.sign(jwk, OIDCTestHelpers.claims(nonce: "n", aud: "someone-else"))
      assert {:error, :invalid_token} = OIDC.validate_id_token(p, c, token, "n")
    end

    test "rejects a wrong issuer", %{provider: p, connection: c, jwk: jwk} do
      token =
        OIDCTestHelpers.sign(
          jwk,
          OIDCTestHelpers.claims(nonce: "n", iss: "https://evil.example.com")
        )

      assert {:error, :invalid_token} = OIDC.validate_id_token(p, c, token, "n")
    end

    test "rejects an expired token beyond the clock skew", %{provider: p, connection: c, jwk: jwk} do
      token =
        OIDCTestHelpers.sign(
          jwk,
          OIDCTestHelpers.claims(nonce: "n", exp: System.system_time(:second) - 120)
        )

      assert {:error, :token_expired} = OIDC.validate_id_token(p, c, token, "n")
    end

    test "rejects a token signed by another key", %{provider: p, connection: c} do
      token =
        OIDCTestHelpers.sign(OIDCTestHelpers.signing_key(), OIDCTestHelpers.claims(nonce: "n"))

      assert {:error, :invalid_token} = OIDC.validate_id_token(p, c, token, "n")
    end

    test "rejects alg none", %{provider: p, connection: c} do
      token = [nonce: "n"] |> OIDCTestHelpers.claims() |> OIDCTestHelpers.unsigned()
      assert {:error, :invalid_token} = OIDC.validate_id_token(p, c, token, "n")
    end

    test "rejects HS256 signed with the client secret", %{provider: p, connection: c} do
      secret_key = JOSE.JWK.from_oct(c.client_secret)

      {_jws, token} =
        secret_key
        |> JOSE.JWT.sign(%{"alg" => "HS256"}, OIDCTestHelpers.claims(nonce: "n"))
        |> JOSE.JWS.compact()

      assert {:error, :invalid_token} = OIDC.validate_id_token(p, c, token, "n")
    end

    test "rejects garbage", %{provider: p, connection: c} do
      assert {:error, :invalid_token} = OIDC.validate_id_token(p, c, "not.a.jwt", "n")
    end
  end
end
