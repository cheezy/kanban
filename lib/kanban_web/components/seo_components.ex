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

  # The daisyUI base-100 background of each theme (assets/css/app.css).
  @theme_color_light "#f8f8f8"
  @theme_color_dark "#151618"

  @doc """
  Renders the search and social meta tags for a page.

  A blank `title` falls back to "Stride" and a blank `description` to
  `default_description/0`. The robots tag is emitted only when `noindex` is
  exactly `true`. Canonical and `og:url` are left out when `path` is `nil`.
  """
  attr :title, :string, default: nil, doc: "the page title, usually assigns[:page_title]"

  attr :description, :string,
    default: nil,
    doc: "the meta description, usually assigns[:meta_description]"

  attr :path, :string, default: nil, doc: "the request path, see request_path/1"
  attr :noindex, :boolean, default: false, doc: "emit robots noindex,nofollow when true"
  attr :og_image, :string, default: nil, doc: "an absolute image URL for og:image"

  attr :locale, :string,
    default: nil,
    doc: "the Gettext locale; nil uses the current Gettext locale"

  def seo_head(assigns) do
    description = present(assigns.description) || default_description()

    assigns =
      assigns
      |> assign(:resolved_title, present(assigns.title) || gettext("Stride"))
      |> assign(:resolved_description, description)
      |> assign(:canonical_url, canonical_url(assigns.path))
      |> assign(:og_locale, og_locale(assigns.locale || Gettext.get_locale(KanbanWeb.Gettext)))
      |> assign(:theme_light, @theme_color_light)
      |> assign(:theme_dark, @theme_color_dark)

    ~H"""
    <meta name="description" content={@resolved_description} />
    <link :if={@canonical_url} rel="canonical" href={@canonical_url} />
    <meta :if={@noindex == true} name="robots" content="noindex, nofollow" />
    <meta property="og:type" content="website" />
    <meta property="og:site_name" content="Stride" />
    <meta property="og:title" content={@resolved_title} />
    <meta property="og:description" content={@resolved_description} />
    <meta :if={@canonical_url} property="og:url" content={@canonical_url} />
    <meta property="og:locale" content={@og_locale} />
    <meta :if={@og_image} property="og:image" content={@og_image} />
    <meta name="twitter:card" content="summary_large_image" />
    <meta name="twitter:title" content={@resolved_title} />
    <meta name="twitter:description" content={@resolved_description} />
    <meta :if={@og_image} name="twitter:image" content={@og_image} />
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
