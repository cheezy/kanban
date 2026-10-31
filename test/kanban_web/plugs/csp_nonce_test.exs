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
      assert policy =~ "img-src 'self' data:"
      assert policy =~ "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com"
      # W2534: the Google Fonts files app.css @imports for the marketing pages and the
      # signed-in .stride-screen app screens (self-hosted instead by D402).
      assert policy =~ "font-src 'self' https://fonts.gstatic.com"
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

    test "allows Google Fonts only for stylesheets and font files, never for scripts" do
      conn = conn(:get, "/") |> CspNonce.call([])

      [policy] = get_resp_header(conn, "content-security-policy")

      directives =
        policy
        |> String.split(";")
        |> Map.new(fn directive ->
          [name | sources] = directive |> String.trim() |> String.split(" ")
          {name, sources}
        end)

      assert "https://fonts.googleapis.com" in directives["style-src"]
      assert directives["font-src"] == ["'self'", "https://fonts.gstatic.com"]

      for {name, sources} <- directives, name not in ["style-src", "font-src"] do
        refute Enum.any?(sources, &String.contains?(&1, "fonts.")),
               "#{name} must not name a Google Fonts host"
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
end
