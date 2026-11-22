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
  other default security headers (X-Content-Type-Options, Referrer-Policy,
  etc.). Phoenix 1.8 sends no X-Frame-Options: it guards against framing
  only through `frame-ancestors` in its default policy, which this header
  replaces, so the policy states `frame-ancestors 'self'` itself.
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
    |> put_resp_header("content-security-policy", policy(nonce))
  end

  @doc """
  Replaces the response's policy with `policy/2` for the nonce this plug
  already assigned, so templates keep using the same `@csp_nonce`. A
  controller calls it to widen one directive for its own pages only.
  """
  @spec put_policy(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def put_policy(%Plug.Conn{assigns: %{csp_nonce: nonce}} = conn, opts) when is_list(opts) do
    put_resp_header(conn, "content-security-policy", policy(nonce, opts))
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
  #
  # D113: add base-uri/form-action/object-src. `base-uri` does NOT fall back to
  # default-src, so without it an injected <base> tag could rehome relative
  # script/resource URLs to an attacker origin; object-src 'none' and
  # form-action 'self' close the plugin and form-hijack sinks. Removing
  # style-src 'unsafe-inline' is intentionally deferred (the LiveView inline-style
  # migration above); the residual risk is CSS-only defacement.
  #
  # D402: Geist, Geist Mono and Silkscreen are self-hosted under /fonts
  # (priv/static/fonts) and declared with @font-face in app.css, so no
  # stylesheet or font file comes from a third-party host: style-src is 'self'
  # plus the 'unsafe-inline' explained above, and font-src is 'self'. font-src
  # is stated even though default-src 'self' covers it, so the font policy stays
  # explicit and a test pins it. W2534 had allowed the two Google Fonts hosts;
  # D402 removed them so no page sends a visitor's IP address or User-Agent to
  # a font CDN. script-src is unchanged.
  #
  # W2512: img-src adds blob: because Phoenix.Component.live_img_preview/1 draws
  # a staged upload's thumbnail from a blob: object URL that LiveView's own
  # (nonce-gated) script creates from the user's local file. blob: only admits
  # object URLs the page itself minted, never a remote image; it is added to
  # img-src alone, so script-src and default-src are unchanged.
  #
  # frame-ancestors 'self' (G489 exploratory session, 2026-11-02): this
  # policy replaces Phoenix's default "base-uri 'self'; frame-ancestors
  # 'self';" and Phoenix 1.8 sends no X-Frame-Options, so without it every
  # page, log-in and settings included, could be framed by another origin
  # (clickjacking). frame-ancestors does not fall back to default-src. In dev
  # the Tidewave plug removes it again so its own UI can frame the app.
  #
  # W2745: `form_action:` appends sources to form-action, after 'self'. Browsers
  # apply form-action to the redirects that follow a form POST, so the device
  # sign-in page (KanbanWeb.OAuthController) adds the apps' private-use scheme
  # there: its Allow and Cancel POSTs redirect to com.stridelikeaboss.app:.
  # The sources come from code, never from a request, and every other page
  # keeps form-action 'self' alone.
  #
  # W2897: when Umami analytics is configured (KanbanWeb.Analytics.config/0),
  # script-src adds the tracker script's origin and a connect-src directive
  # allows 'self' plus the origin the tracker sends events to. Both come from
  # config/runtime.exs, never from a request, and are exact origins, never a
  # wildcard. connect-src keeps 'self', which default-src already gave it, so
  # the LiveView socket and long-poll fallback are unaffected. Without the
  # configuration the policy is unchanged.
  @doc """
  The policy for `nonce`. `opts[:form_action]` is a list of extra
  `form-action` sources, appended after `'self'`; with no options the policy
  is the one every page gets.
  """
  @spec policy(String.t(), keyword()) :: String.t()
  def policy(nonce, opts \\ []) do
    form_action = Enum.join(["'self'" | Keyword.get(opts, :form_action, [])], " ")
    {script_extra, connect} = analytics_sources(KanbanWeb.Analytics.config())

    """
    default-src 'self'; \
    script-src 'self' 'nonce-#{nonce}'#{script_extra}; \
    #{connect}img-src 'self' data: blob:; \
    style-src 'self' 'unsafe-inline'; \
    font-src 'self'; \
    base-uri 'self'; \
    form-action #{form_action}; \
    object-src 'none'; \
    frame-ancestors 'self'\
    """
  end

  defp analytics_sources(nil), do: {"", ""}

  defp analytics_sources(%{script_origin: script, connect_origin: connect}),
    do: {" " <> script, "connect-src 'self' #{connect}; "}
end
