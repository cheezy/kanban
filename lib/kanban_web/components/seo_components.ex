defmodule KanbanWeb.SeoComponents do
  @moduledoc """
  Search and social tags for the `<head>` of the three root layouts
  (`root`, `app_chrome` and `marketing`).

  Every layout calls `seo_head/1` once, right after its `live_title`, so each
  page gets the same description, canonical, robots, Open Graph, Twitter card,
  `og:locale` and `theme-color` tags from one place.

  The canonical URL and `og:url` are built from `KanbanWeb.Endpoint.url/0` and
  the request path only. The Host header and the query string are never used:
  both are attacker-controlled, and the query string would make every
  `?locale=` and `utm_*` variant a separate URL.
  Both are left out on a path that carries a secret token
  (`KanbanWeb.TokenPaths`), as received or percent-decoded, so the token never
  reaches a meta tag.

  Every page gets an `og:image` and `twitter:image`: the 1200x630 PNG at
  `priv/static/images/og/stride-og.png` by default, with its `og:image:width`,
  `og:image:height` and translated `og:image:alt`, or the page's own
  `og_image` assign. Both are absolute URLs, because link-preview crawlers
  ignore relative ones.

  `structured_data/1` renders a schema.org JSON-LD block. Pages call it from
  their own template rather than the layout: the home page passes an
  `Organization` and the pricing page a `SoftwareApplication`, both built in
  `KanbanWeb.PageHTML`.

  Note that live navigation inside one `live_session` does not re-render the
  root layout, so the canonical keeps the path of the first full page load
  until the next full load. Crawlers always do full loads.
  """
  use KanbanWeb, :html

  alias KanbanWeb.TokenPaths

  @og_locales %{
    "de" => "de_DE",
    "en" => "en_US",
    "es" => "es_ES",
    "fr" => "fr_FR",
    "ja" => "ja_JP",
    "pt" => "pt_BR",
    "zh" => "zh_CN"
  }

  @default_og_locale "en_US"

  # The default link-preview image, a raster PNG because Slack, LinkedIn and X
  # do not render an SVG preview.
  @og_image_path "/images/og/stride-og.png"
  @og_image_width 1200
  @og_image_height 630

  # The daisyUI base-100 background of each theme (assets/css/app.css).
  @theme_color_light "#f8f8f8"
  @theme_color_dark "#151618"

  @doc """
  Renders the search and social meta tags for a page.

  A blank `title` falls back to "Stride" and a blank `description` to
  `default_description/0`. The robots tag is emitted only when `noindex` is
  exactly `true`. Canonical and `og:url` are left out when `path` is `nil`.
  A `rel="alternate"` Atom link is emitted only when `feed_path` is set, with
  its `href` made absolute the same way as the canonical URL.

  A page's own `og_image` is made absolute (see `og_image_url/1`) and carries
  no width, height or alt, since those describe the default image only. A
  blank `og_image`, or one `og_image_url/1` cannot make absolute, falls back
  to `default_og_image_url/0` with the default image's width, height and alt.
  """
  attr :title, :string, default: nil, doc: "the page title, usually assigns[:page_title]"

  attr :description, :string,
    default: nil,
    doc: "the meta description, usually assigns[:meta_description]"

  attr :path, :string, default: nil, doc: "the request path, see request_path/1"
  attr :noindex, :boolean, default: false, doc: "emit robots noindex,nofollow when true"

  attr :og_image, :string,
    default: nil,
    doc: "the og:image URL or path, usually assigns[:og_image]; nil uses the default"

  attr :locale, :string,
    default: nil,
    doc: "the Gettext locale; nil uses the current Gettext locale"

  attr :feed_path, :string,
    default: nil,
    doc: "the path of the page's Atom feed, usually assigns[:feed_path]; nil emits no feed link"

  attr :feed_title, :string,
    default: nil,
    doc: "the title of the feed link, usually assigns[:feed_title]"

  def seo_head(assigns) do
    description = present(assigns.description) || default_description()

    assigns =
      assigns
      |> assign(:resolved_title, present(assigns.title) || gettext("Stride"))
      |> assign(:resolved_description, description)
      |> assign(:canonical_url, canonical_url(assigns.path))
      |> assign(:feed_url, canonical_url(assigns.feed_path))
      |> assign(:og_locale, og_locale(assigns.locale || Gettext.get_locale(KanbanWeb.Gettext)))
      |> assign_og_image()
      |> assign(:theme_light, @theme_color_light)
      |> assign(:theme_dark, @theme_color_dark)

    ~H"""
    <meta name="description" content={@resolved_description} />
    <link :if={@canonical_url} rel="canonical" href={@canonical_url} />
    <meta :if={@noindex == true} name="robots" content="noindex, nofollow" />
    <link
      :if={@feed_url}
      rel="alternate"
      type="application/atom+xml"
      title={@feed_title}
      href={@feed_url}
    />
    <meta property="og:type" content="website" />
    <meta property="og:site_name" content="Stride" />
    <meta property="og:title" content={@resolved_title} />
    <meta property="og:description" content={@resolved_description} />
    <meta :if={@canonical_url} property="og:url" content={@canonical_url} />
    <meta property="og:locale" content={@og_locale} />
    <meta property="og:image" content={@og_image_url} />
    <meta :if={@og_image_default?} property="og:image:width" content={@og_image_width} />
    <meta :if={@og_image_default?} property="og:image:height" content={@og_image_height} />
    <meta :if={@og_image_default?} property="og:image:alt" content={@og_image_alt} />
    <meta name="twitter:card" content="summary_large_image" />
    <meta name="twitter:title" content={@resolved_title} />
    <meta name="twitter:description" content={@resolved_description} />
    <meta name="twitter:image" content={@og_image_url} />
    <meta :if={@og_image_default?} name="twitter:image:alt" content={@og_image_alt} />
    <meta name="theme-color" content={@theme_light} media="(prefers-color-scheme: light)" />
    <meta name="theme-color" content={@theme_dark} media="(prefers-color-scheme: dark)" />
    """
  end

  @doc """
  The translated description used when a page sets no `meta_description`.
  """
  def default_description do
    gettext(
      "Stride is a kanban board where humans and AI agents plan, claim and ship work together."
    )
  end

  @doc """
  The absolute URL of the default link-preview image, through the static path
  so a digested asset name is used when the cache manifest is loaded.
  """
  def default_og_image_url, do: og_image_url(@og_image_path)

  @doc """
  The translated alt text of the default link-preview image.
  """
  def default_og_image_alt do
    gettext("The Stride logo beside the words: Kanban for humans and AI agents")
  end

  @doc """
  Makes an `og:image` value absolute.

  An `http://` or `https://` URL is kept as it is. A path starting with a
  single `/` is resolved through the endpoint's static URL and static path.
  Anything else, including a protocol-relative `//host/...` value, returns
  `nil`, because platforms ignore a relative `og:image`.
  """
  def og_image_url("//" <> _rest), do: nil

  def og_image_url("/" <> _rest = path) do
    KanbanWeb.Endpoint.static_url() <> KanbanWeb.Endpoint.static_path(path)
  end

  def og_image_url(value) when is_binary(value) do
    if absolute_http_url?(value), do: value
  end

  def og_image_url(_value), do: nil

  @doc """
  Maps a Gettext locale to its Open Graph form, falling back to `en_US`.
  """
  def og_locale(locale) when is_binary(locale),
    do: Map.get(@og_locales, locale, @default_og_locale)

  def og_locale(_locale), do: @default_og_locale

  @doc """
  Builds the canonical URL from the endpoint URL and a request path.

  Anything after a `?` or `#` is dropped, and runs of slashes collapse to one
  with no trailing slash (except on `/`), because the router ignores empty
  segments. Percent-encoding is kept as it is. Returns `nil` for `nil`, for a
  path that does not start with `/`, for a path with a `.` or `..` segment
  (literal or percent-encoded), which a URL parser would resolve to another
  page, and for a path that carries a secret
  token segment (`KanbanWeb.TokenPaths`), as received or percent-decoded, so
  an invitation, password reset or confirmation token never reaches the
  canonical link or `og:url`.
  """
  def canonical_url(path) when is_binary(path) do
    [bare | _] = String.split(path, ["?", "#"], parts: 2)

    if canonical_path?(bare), do: KanbanWeb.Endpoint.url() <> normalize_path(bare)
  end

  def canonical_url(_path), do: nil

  @doc """
  Returns the request path of a conn, or `nil` when there is no conn.
  """
  def request_path(%Plug.Conn{request_path: path}), do: path
  def request_path(_conn), do: nil

  @doc """
  Renders a schema.org JSON-LD block in a `<script type="application/ld+json">`
  tag.

  `data` must be a map built in code, never request params. It is encoded by
  `encode_json_ld/1`, which escapes every `<` and `/`, so no value can close
  the script element or open a comment, and only that encoded string is
  emitted unescaped. A browser does not decode HTML entities inside a script
  element, which is why the JSON is escaped rather than the HTML.

  Pass the request's CSP nonce as `nonce` (usually `assigns[:csp_nonce]`); a
  component cannot read its caller's assigns. The policy is never loosened for
  this block.
  """
  attr :data, :map, required: true, doc: "the schema.org map, built in code"
  attr :nonce, :string, default: nil, doc: "the request CSP nonce"

  def structured_data(assigns) do
    assigns = assign(assigns, :json, encode_json_ld(assigns.data))

    ~H"""
    <script type="application/ld+json" nonce={@nonce}>
      <%= raw(@json) %>
    </script>
    """
  end

  @doc """
  Encodes a map as JSON that is safe inside a `<script>` element: `<` becomes
  `\\u003C` and `/` becomes `\\/`, both of which decode back to the same
  string.
  """
  def encode_json_ld(data) when is_map(data), do: Jason.encode!(data, escape: :html_safe)

  defp assign_og_image(assigns) do
    case assigns.og_image |> present() |> og_image_url() do
      nil ->
        assigns
        |> assign(:og_image_url, default_og_image_url())
        |> assign(:og_image_default?, true)
        |> assign(:og_image_width, @og_image_width)
        |> assign(:og_image_height, @og_image_height)
        |> assign(:og_image_alt, default_og_image_alt())

      url ->
        assigns
        |> assign(:og_image_url, url)
        |> assign(:og_image_default?, false)
        |> assign(:og_image_width, nil)
        |> assign(:og_image_height, nil)
        |> assign(:og_image_alt, nil)
    end
  end

  defp absolute_http_url?(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        host != ""

      _uri ->
        false
    end
  end

  # The router matches on the percent-decoded path, so `/%69nvitations/<token>`
  # reaches the invitation page too. Check the decoded form as well.
  defp canonical_path?("/" <> _ = path) do
    not secret_path?(path) and not (path |> segments() |> Enum.any?(&dot_segment?/1))
  end

  defp canonical_path?(_path), do: false

  defp secret_path?(path) do
    TokenPaths.token_path?(path) or path |> URI.decode() |> TokenPaths.token_path?()
  end

  defp dot_segment?(segment), do: URI.decode(segment) in [".", ".."]

  defp segments(path), do: String.split(path, "/", trim: true)

  defp normalize_path(path), do: "/" <> (path |> segments() |> Enum.join("/"))

  defp present(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp present(_value), do: nil
end
