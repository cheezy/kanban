defmodule KanbanWeb.Plugs.CspNonceTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias KanbanWeb.Plugs.CspNonce

  describe "generate_nonce/0" do
    test "returns a URL-safe base64 string" do
      nonce = CspNonce.generate_nonce()

      assert is_binary(nonce)
      assert nonce =~ ~r/\A[A-Za-z0-9_-]+\z/
    end

    test "encodes at least 128 bits of entropy" do
      nonce = CspNonce.generate_nonce()
      # 16 raw bytes → ceil(16 * 4 / 3) = 22 base64 chars (no padding).
      assert byte_size(nonce) >= 22
    end

    test "produces a different nonce on every call" do
      assert CspNonce.generate_nonce() != CspNonce.generate_nonce()
    end
  end

  describe "call/2" do
    test "assigns :csp_nonce on the conn" do
      conn = conn(:get, "/") |> CspNonce.call([])

      assert is_binary(conn.assigns.csp_nonce)
      assert conn.assigns.csp_nonce =~ ~r/\A[A-Za-z0-9_-]+\z/
    end

    test "sets the content-security-policy header" do
      conn = conn(:get, "/") |> CspNonce.call([])

      [policy] = get_resp_header(conn, "content-security-policy")
      nonce = conn.assigns.csp_nonce

      assert policy =~ "default-src 'self'"
      assert policy =~ "script-src 'self' 'nonce-#{nonce}'"
      # W2512: blob: for live_img_preview (the ; makes it exact).
      assert policy =~ "img-src 'self' data: blob:;"
      # D402: fonts are self-hosted, so both end at 'self' (the ; makes it exact).
      assert policy =~ "style-src 'self' 'unsafe-inline';"
      assert policy =~ "font-src 'self';"
      # D113: hardening directives — base-uri does not fall back to default-src.
      assert policy =~ "base-uri 'self'"
      assert policy =~ "form-action 'self'"
      assert policy =~ "object-src 'none'"
    end

    test "script-src does NOT include 'unsafe-inline'" do
      conn = conn(:get, "/") |> CspNonce.call([])

      [policy] = get_resp_header(conn, "content-security-policy")

      # Extract the script-src directive and assert it lacks unsafe-inline.
      script_directive =
        policy
        |> String.split(";")
        |> Enum.map(&String.trim/1)
        |> Enum.find(&String.starts_with?(&1, "script-src"))

      assert script_directive
      refute script_directive =~ "unsafe-inline"
    end

    test "CspNonce policy names no fonts.googleapis.com or fonts.gstatic.com host in any directive" do
      [policy] =
        conn(:get, "/") |> CspNonce.call([]) |> get_resp_header("content-security-policy")

      for {name, sources} <- directives(policy), source <- sources do
        refute source =~ ~r/fonts\.googleapis\.com|fonts\.gstatic\.com/,
               "#{name} must not name a Google Fonts host"
      end

      refute policy =~ "fonts.googleapis.com"
      refute policy =~ "fonts.gstatic.com"
    end

    test "CspNonce style-src is 'self' 'unsafe-inline' and fonts are allowed only from 'self'" do
      [policy] =
        conn(:get, "/") |> CspNonce.call([]) |> get_resp_header("content-security-policy")

      directives = directives(policy)

      assert directives["style-src"] == ["'self'", "'unsafe-inline'"]
      assert directives["font-src"] == ["'self'"]
      assert directives["default-src"] == ["'self'"]
    end

    test "img-src allows self, data: and blob: and nothing else" do
      [policy] =
        conn(:get, "/") |> CspNonce.call([]) |> get_resp_header("content-security-policy")

      directives = directives(policy)
      nonce_source = Enum.find(directives["script-src"], &String.starts_with?(&1, "'nonce-"))

      assert directives["img-src"] == ["'self'", "data:", "blob:"]

      # Every other directive is exactly what it was before blob: was added.
      assert Map.delete(directives, "img-src") == %{
               "default-src" => ["'self'"],
               "script-src" => ["'self'", nonce_source],
               "style-src" => ["'self'", "'unsafe-inline'"],
               "font-src" => ["'self'"],
               "base-uri" => ["'self'"],
               "form-action" => ["'self'"],
               "object-src" => ["'none'"]
             }

      for {name, sources} <- Map.delete(directives, "img-src") do
        refute "blob:" in sources, "#{name} must not allow blob:"
      end
    end

    test "two requests get two different nonces (no caching)" do
      nonce1 = conn(:get, "/") |> CspNonce.call([]) |> Map.get(:assigns) |> Map.get(:csp_nonce)
      nonce2 = conn(:get, "/") |> CspNonce.call([]) |> Map.get(:assigns) |> Map.get(:csp_nonce)

      assert nonce1 != nonce2
    end

    test "overwrites a pre-existing content-security-policy header" do
      # The :browser pipeline sets a static CSP placeholder via
      # put_secure_browser_headers so Sobelow's Config.CSP static check sees a
      # policy declared at the router. CspNonce must overwrite that header at
      # runtime so the actual response carries the per-request nonce.
      conn =
        conn(:get, "/")
        |> put_resp_header("content-security-policy", "default-src 'self'")
        |> CspNonce.call([])

      headers = get_resp_header(conn, "content-security-policy")

      # Single value (overwrite, not append).
      assert length(headers) == 1

      [policy] = headers
      assert policy =~ "'nonce-#{conn.assigns.csp_nonce}'"
      refute policy == "default-src 'self'"
    end
  end

  defp directives(policy) do
    policy
    |> String.split(";", trim: true)
    |> Map.new(fn directive ->
      [name | sources] = String.split(directive)
      {name, sources}
    end)
  end
end
