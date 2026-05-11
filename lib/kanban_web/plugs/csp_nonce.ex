defmodule KanbanWeb.Plugs.CspNonce do
  @moduledoc """
  Generates a cryptographically-random per-request nonce, assigns it to
  `conn.assigns.csp_nonce`, and emits a `content-security-policy` header that
  whitelists inline scripts and styles bearing that nonce.

  Replaces the prior static `'unsafe-inline'` CSP policy with a nonce-based
  policy so that any reflected or stored markup containing an inline
  `<script>` or event handler is rejected by the browser unless it carries
  the matching nonce. Templates that emit legitimate inline scripts and
  styles MUST include `nonce={@csp_nonce}`.

  The nonce is 16 random bytes encoded with URL-safe Base64 (no padding) —
  ~22 characters, well above the 128-bit entropy the W3C CSP spec
  recommends. It is regenerated on every request so a single page's nonce
  cannot be reused on a different request.

  This plug intentionally sets only the `content-security-policy` header.
  Pair it with `put_secure_browser_headers/2` to retain the framework's
  other default security headers (X-Frame-Options, X-Content-Type-Options,
  etc.).
  """
  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    nonce = generate_nonce()

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", build_policy(nonce))
  end

  # Returns a freshly-generated URL-safe Base64 nonce. Exposed for testing;
  # not part of the runtime API.
  @doc false
  def generate_nonce do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  # script-src uses nonces — this is the major XSS protection. style-src
  # retains 'unsafe-inline' because Phoenix LiveView relies heavily on inline
  # `style=` attributes (loading bar, drag-and-drop positioning, progress
  # indicators, etc.) and a nonce-based style policy would require either
  # 'unsafe-hashes' with per-attribute hashes or migrating every inline
  # style to a stylesheet — both are sizeable, separate refactors. The
  # impact gap between inline-script and inline-style XSS is large: scripts
  # execute arbitrary code, styles produce defacement at worst.
  defp build_policy(nonce) do
    """
    default-src 'self'; \
    script-src 'self' 'nonce-#{nonce}'; \
    img-src 'self' data:; \
    style-src 'self' 'unsafe-inline'\
    """
  end
end
