defmodule KanbanWeb.AuditSigningKeysControllerTest do
  # async: false — tests here replace the application config of
  # Kanban.AuditLog.Signing, which is global.
  use KanbanWeb.ConnCase, async: false

  import Kanban.AccountsFixtures

  alias Kanban.AuditLog.Signing

  @path "/.well-known/stride-audit-signing-keys"
  @public_cache "public, max-age=3600"

  setup do
    saved = Application.fetch_env(:kanban, Signing)

    on_exit(fn ->
      case saved do
        {:ok, config} -> Application.put_env(:kanban, Signing, config)
        :error -> Application.delete_env(:kanban, Signing)
      end
    end)
  end

  defp configure(config), do: Application.put_env(:kanban, Signing, config)

  defp seed, do: :crypto.strong_rand_bytes(32)

  # Computed by :crypto and Base here, not by Signing, so the tests don't
  # check the endpoint against the module it renders.
  defp public_key(seed) do
    {public_key, _private_key} = :crypto.generate_key(:eddsa, :ed25519, seed)
    public_key
  end

  defp kid(public_key) do
    "k1-" <>
      (:sha256 |> :crypto.hash(public_key) |> Base.encode16(case: :lower) |> binary_part(0, 16))
  end

  defp x(public_key), do: Base.url_encode64(public_key, padding: false)

  # One current key, two previous keys and one revoked key with a date.
  defp key_ring(_context) do
    current = seed()
    previous = [public_key(seed()), public_key(seed())]
    revoked = public_key(seed())

    configure(
      private_key: current,
      previous: previous,
      revoked: [{revoked, ~D[2026-11-10]}]
    )

    %{current: public_key(current), previous: previous, revoked: revoked}
  end

  defp pem_path(kid), do: @path <> "?" <> URI.encode_query(%{"format" => "pem", "kid" => kid})

  defp response_text(conn) do
    headers = Enum.map_join(conn.resp_headers, "\n", fn {name, value} -> "#{name}: #{value}" end)
    headers <> "\n" <> conn.resp_body
  end

  describe "the JSON Web Key Set" do
    setup :key_ring

    test "JWKS lists current then previous keys with kty, crv, kid and unpadded x",
         %{conn: conn, current: current, previous: [first, second]} do
      conn = get(conn, @path)

      assert %{"keys" => keys, "revoked" => [_revoked]} = json_response(conn, 200)
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"

      expected =
        for public_key <- [current, first, second] do
          %{
            "kty" => "OKP",
            "crv" => "Ed25519",
            "use" => "sig",
            "alg" => "EdDSA",
            "kid" => kid(public_key),
            "x" => x(public_key)
          }
        end

      assert keys == expected

      for %{"x" => x} <- keys do
        refute x =~ "="
        assert byte_size(Base.url_decode64!(x, padding: false)) == 32
      end
    end

    test "revoked list carries kid and revoked_at, and a revoked key is absent from keys",
         %{conn: conn, revoked: revoked} do
      body = conn |> get(@path) |> json_response(200)

      assert body["revoked"] == [%{"kid" => kid(revoked), "revoked_at" => "2026-11-10"}]
      refute kid(revoked) in Enum.map(body["keys"], & &1["kid"])
      refute x(revoked) in Enum.map(body["keys"], & &1["x"])
    end

    test "a revoked key with no configured date has a null revoked_at", %{conn: conn} do
      revoked = public_key(seed())
      configure(private_key: seed(), revoked: [revoked])

      body = conn |> get(@path) |> json_response(200)

      assert body["revoked"] == [%{"kid" => kid(revoked), "revoked_at" => nil}]
    end

    test "a key listed as previous and revoked is published only as revoked", %{conn: conn} do
      leaked = public_key(seed())
      configure(private_key: seed(), previous: [leaked], revoked: [{leaked, ~D[2026-01-02]}])

      body = conn |> get(@path) |> json_response(200)

      assert [%{"kid" => current_kid}] = body["keys"]
      refute current_kid == kid(leaked)
      assert body["revoked"] == [%{"kid" => kid(leaked), "revoked_at" => "2026-01-02"}]
    end

    test "signing off with no previous keys gives an empty keys array", %{conn: conn} do
      configure(fallback: :none)

      conn = get(conn, @path)

      assert json_response(conn, 200) == %{"keys" => [], "revoked" => []}
      assert get_resp_header(conn, "cache-control") == [@public_cache]
    end

    test "signing off but previous keys still configured: keys holds only the previous ones",
         %{conn: conn} do
      previous = public_key(seed())
      configure(fallback: :none, previous: [previous])

      body = conn |> get(@path) |> json_response(200)

      assert Enum.map(body["keys"], & &1["kid"]) == [kid(previous)]
    end

    test "a Signing.sign/1 signature verifies against the fetched JWKS x value",
         %{conn: conn} do
      nonce = 8 |> :crypto.strong_rand_bytes() |> Base.encode16()
      message = "audit export manifest " <> nonce
      assert {:ok, %{signature: signature, key_id: key_id}} = Signing.sign(message)

      %{"keys" => keys} = conn |> get(@path) |> json_response(200)
      assert %{"x" => x} = Enum.find(keys, &(&1["kid"] == key_id))
      public_key = Base.url_decode64!(x, padding: false)

      assert :crypto.verify(:eddsa, :none, message, signature, [public_key, :ed25519])
      refute :crypto.verify(:eddsa, :none, message <> "!", signature, [public_key, :ed25519])
    end

    test "concurrent requests return identical bodies", %{conn: conn} do
      expected = conn |> get(@path) |> response(200)

      bodies =
        1..20
        |> Task.async_stream(fn _request -> build_conn() |> get(@path) |> response(200) end,
          max_concurrency: 20
        )
        |> Enum.map(fn {:ok, body} -> body end)

      assert length(bodies) == 20
      assert Enum.uniq(bodies) == [expected]
    end

    test "the kid param is ignored without format=pem", %{conn: conn} do
      plain = conn |> get(@path) |> response(200)

      assert build_conn() |> get(@path, %{"kid" => "k1-0000000000000000"}) |> response(200) ==
               plain
    end
  end

  describe "one key as PEM" do
    setup :key_ring

    test "format=pem with a current or previous kid returns one PEM that decodes to the same 32 bytes",
         %{current: current, previous: previous} do
      for public_key <- [current | previous] do
        conn = get(build_conn(), pem_path(kid(public_key)))

        body = response(conn, 200)
        assert [content_type] = get_resp_header(conn, "content-type")
        assert content_type =~ "application/x-pem-file"

        assert [{:SubjectPublicKeyInfo, der, :not_encrypted}] = :public_key.pem_decode(body)
        assert byte_size(der) == 44
        assert binary_part(der, byte_size(der) - 32, 32) == public_key

        assert body =~
                 ~r/\A-----BEGIN PUBLIC KEY-----\n[A-Za-z0-9+\/=]+\n-----END PUBLIC KEY-----\n\z/
      end
    end

    test "format=pem with a revoked, unknown, malformed or missing kid returns 404",
         %{current: current, revoked: revoked} do
      current_kid = kid(current)
      "k1-" <> hex = current_kid

      refused = [
        {"revoked", kid(revoked)},
        {"unknown", kid(public_key(seed()))},
        {"uppercase hex", "k1-" <> String.upcase(hex)},
        {"uppercase prefix", "K1-" <> hex},
        {"trailing newline", current_kid <> "\n"},
        {"leading space", " " <> current_kid},
        {"too short", binary_part(current_kid, 0, 18)},
        {"too long", current_kid <> "0"},
        {"no prefix", hex},
        {"empty", ""},
        {"not hex", "k1-zzzzzzzzzzzzzzzz"}
      ]

      for {reason, kid} <- refused do
        conn = get(build_conn(), pem_path(kid))

        assert json_response(conn, 404) == %{"errors" => %{"detail" => "Not Found"}},
               "expected a 404 for a #{reason} kid"
      end

      missing = get(build_conn(), @path, %{"format" => "pem"})
      assert json_response(missing, 404) == %{"errors" => %{"detail" => "Not Found"}}

      # The uppercase kid is refused by its shape, not because the key is
      # unknown: the same key in lowercase is served.
      assert build_conn() |> get(pem_path(current_kid)) |> response(200)
    end

    test "a kid given twice is a 404 as a list and its last value otherwise", %{current: current} do
      current_kid = kid(current)

      listed = get(build_conn(), @path <> "?format=pem&kid[]=#{current_kid}&kid[]=#{current_kid}")
      assert json_response(listed, 404)

      # Plug keeps the last of two plain values, so the lookup sees only it.
      last_unknown =
        get(build_conn(), @path <> "?format=pem&kid=#{current_kid}&kid=k1-0000000000000000")

      assert json_response(last_unknown, 404)

      last_known =
        get(build_conn(), @path <> "?format=pem&kid=k1-0000000000000000&kid=#{current_kid}")

      assert response(last_known, 200) =~ "BEGIN PUBLIC KEY"
    end

    test "the kid from the query is never echoed in a response body or header", %{
      revoked: revoked
    } do
      for kid <- [
            kid(revoked),
            "k1-0123456789abcdef",
            "k1-echo-marker-7f3a",
            "<script>k1</script>"
          ] do
        conn = get(build_conn(), pem_path(kid))

        assert conn.status == 404
        refute response_text(conn) =~ kid
        refute response_text(conn) =~ URI.encode_www_form(kid)
      end
    end

    test "a query string that is not valid UTF-8 is a JSON 400 that never repeats it", %{
      current: current
    } do
      # Refused by the endpoint's parsers before the router runs, so this is
      # the endpoint's error rendering, pinned to JSON for this address by
      # KanbanWeb.Plugs.Parsers, and not the controller's 404.
      for query <- ["format=pem&kid=#{kid(current)}%FF", "kid=%FF", "format=pem&kid=%C0%80"],
          accept <- [nil, "text/html", "application/x-pem-file"] do
        conn = if accept, do: put_req_header(build_conn(), "accept", accept), else: build_conn()

        {400, headers, body} =
          assert_error_sent 400, fn -> get(conn, @path <> "?" <> query) end

        assert Jason.decode!(body) == %{"errors" => %{"detail" => "Bad Request"}}
        assert {"content-type", "application/json; charset=utf-8"} in headers
        refute List.keymember?(headers, "set-cookie", 0)
        refute {"cache-control", @public_cache} in headers
        refute body =~ kid(current)
      end
    end

    # W2724: %ZZ is not a percent escape, so it decodes as the three
    # characters "%ZZ" rather than failing like the invalid UTF-8 above. The
    # paths are written out because pem_path/1 would encode it as %25ZZ.
    test "a malformed percent escape such as %ZZ is read as literal text, not refused" do
      jwks = build_conn() |> get(@path) |> json_response(200)

      for path <- [@path <> "?kid=%ZZ", @path <> "/?kid=%ZZ"] do
        conn = get(build_conn(), path)

        assert conn.query_params == %{"kid" => "%ZZ"}
        assert json_response(conn, 200) == jwks
      end

      for path <- [@path <> "?format=pem&kid=%ZZ", @path <> "/?format=pem&kid=%ZZ"] do
        conn = get(build_conn(), path)

        assert conn.query_params == %{"format" => "pem", "kid" => "%ZZ"}
        assert json_response(conn, 404) == %{"errors" => %{"detail" => "Not Found"}}
        assert get_resp_header(conn, "cache-control") == ["no-store"]
        refute response_text(conn) =~ "%ZZ"
      end
    end

    test "an unknown format value returns 404", %{current: current} do
      for format <- ["jwks", "json", "PEM", "pem ", "der", ""] do
        conn = get(build_conn(), @path, %{"format" => format, "kid" => kid(current)})

        assert json_response(conn, 404) == %{"errors" => %{"detail" => "Not Found"}},
               "expected a 404 for format=#{inspect(format)}"

        refute response_text(conn) =~ "BEGIN PUBLIC KEY"
      end

      listed = get(build_conn(), @path <> "?format[]=pem&kid=#{kid(current)}")
      assert json_response(listed, 404)
    end
  end

  describe "a public, sessionless, cacheable route" do
    setup :key_ring

    test "200 responses carry public max-age=3600 and 404s do not", %{current: current} do
      jwks = get(build_conn(), @path)
      assert get_resp_header(jwks, "cache-control") == [@public_cache]

      pem = get(build_conn(), pem_path(kid(current)))
      assert pem.status == 200
      assert get_resp_header(pem, "cache-control") == [@public_cache]

      for path <- [pem_path("k1-0000000000000000"), @path <> "?format=der"] do
        not_found = get(build_conn(), path)

        assert not_found.status == 404
        assert get_resp_header(not_found, "cache-control") == ["no-store"]
      end
    end

    test "no set-cookie header and any Accept header works", %{current: current} do
      plain = build_conn() |> get(@path) |> response(200)

      for accept <- [
            "*/*",
            "application/json",
            "application/x-pem-file",
            "text/html",
            "image/png"
          ] do
        jwks = build_conn() |> put_req_header("accept", accept) |> get(@path)

        assert response(jwks, 200) == plain
        assert get_resp_header(jwks, "set-cookie") == []
        assert jwks.resp_cookies == %{}
        assert get_resp_header(jwks, "cache-control") == [@public_cache]

        pem = build_conn() |> put_req_header("accept", accept) |> get(pem_path(kid(current)))

        assert response(pem, 200) =~ "BEGIN PUBLIC KEY"
        assert get_resp_header(pem, "set-cookie") == []
        assert get_resp_header(pem, "cache-control") == [@public_cache]
      end

      not_found = get(build_conn(), pem_path("k1-0000000000000000"))
      assert not_found.status == 404
      assert get_resp_header(not_found, "set-cookie") == []
    end

    test "the secure headers are set on the JSON, PEM and 404 responses", %{current: current} do
      for path <- [@path, pem_path(kid(current)), pem_path("k1-0000000000000000")] do
        conn = get(build_conn(), path)

        assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

        assert get_resp_header(conn, "content-security-policy") == [
                 "default-src 'none'; frame-ancestors 'none'"
               ]
      end
    end

    test "a signed-in user and an anonymous visitor get the same body", %{
      conn: conn,
      current: current
    } do
      signed_in = log_in_user(conn, user_fixture())

      assert signed_in |> get(@path) |> response(200) ==
               build_conn() |> get(@path) |> response(200)

      # Not recycled: recycle/1 carries cookies over but not the test session,
      # which would leave two anonymous requests to compare.
      signed_in_pem = get(signed_in, pem_path(kid(current)))

      assert response(signed_in_pem, 200) ==
               build_conn() |> get(pem_path(kid(current))) |> response(200)

      assert get_resp_header(signed_in_pem, "set-cookie") == []
    end

    test "the path with a trailing slash serves the same key set" do
      assert build_conn() |> get(@path <> "/") |> response(200) ==
               build_conn() |> get(@path) |> response(200)
    end

    test "HEAD gets the GET headers and no body" do
      conn = head(build_conn(), @path)

      assert response(conn, 200) == ""
      assert get_resp_header(conn, "cache-control") == [@public_cache]
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"
    end

    test "POST, PUT, PATCH and DELETE are not routed" do
      for method <- [:post, :put, :patch, :delete] do
        # No route matches, so the endpoint's own not-found page answers and
        # this controller is never reached.
        conn = dispatch(build_conn(), @endpoint, method, @path)

        assert conn.status == 404
        assert conn.private[:phoenix_controller] == nil
        refute conn.resp_body =~ "\"keys\""
        refute get_resp_header(conn, "cache-control") == [@public_cache]
      end
    end

    test "the response holds public material only, never the private seed", %{current: current} do
      seed = seed()
      configure(private_key: seed, previous: [current])

      for path <- [@path, pem_path(kid(public_key(seed)))] do
        body = build_conn() |> get(path) |> response(200)

        refute body =~ Base.url_encode64(seed, padding: false)
        refute body =~ Base.encode64(seed)
        refute body =~ Base.encode16(seed, case: :lower)
      end
    end
  end
end
