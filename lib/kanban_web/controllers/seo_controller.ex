defmodule KanbanWeb.SeoController do
  @moduledoc """
  Serves `/robots.txt` and `/sitemap.xml` (W2891), the Atom feed of
  releases at `/changelog/feed.xml` (W2896), and `/llms.txt` (W2900).

  `robots.txt` allows crawling, disallows `/api/`, names the AI crawlers in
  their own groups and names the sitemap only when both of these hold:

    * the deployment is indexable: `config :kanban, KanbanWeb.SeoController,
      indexable: true`, which `config/runtime.exs` sets from `SEO_INDEXABLE`
      and only `fly.production.toml` turns on, and
    * the request came to the canonical host, the host of
      `KanbanWeb.Endpoint.url/0` (`www.stridelikeaboss.com` in production).

  Everywhere else it disallows everything: the review app, whose `PHX_HOST`
  makes it its own endpoint host but which is not indexable, the
  `kanban-prod.fly.dev` origin, which is not the canonical host, and dev. So
  no copy is indexed as a duplicate of the real site. The Host header is only
  compared, never written into a response. The bodies, and the AI crawler
  list and policy, come from `KanbanWeb.RobotsTxt`.

  `/llms.txt` is the same on every host: a Markdown summary of Stride with
  absolute links to the canonical site, from `KanbanWeb.LlmsTxt`. Where it is
  served from does not change what it says, and on a host that is not
  indexable `robots.txt` already disallows it for every crawler.

  All four go through the router's `:seo` pipeline, which fetches no session
  and sets no cookie. The sitemap body comes from `KanbanWeb.SeoXML` and the
  feed body from `KanbanWeb.ChangelogFeed`.
  """
  use KanbanWeb, :controller

  alias KanbanWeb.ChangelogFeed
  alias KanbanWeb.Endpoint
  alias KanbanWeb.LlmsTxt
  alias KanbanWeb.PageHTML
  alias KanbanWeb.RobotsTxt
  alias KanbanWeb.SeoXML

  # An hour: crawlers fetch these rarely, and a new page is seen the same day.
  @cache_control "public, max-age=3600"

  @spec robots(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def robots(conn, _params) do
    body = if indexable?(conn.host), do: RobotsTxt.canonical(), else: RobotsTxt.disallow_all()

    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("cache-control", @cache_control)
    |> send_resp(:ok, body)
  end

  # The body is the sitemap from `SeoXML.sitemap/0`, which escapes every value,
  # sent as application/xml, not HTML.
  @spec sitemap(Plug.Conn.t(), map()) :: Plug.Conn.t()
  # sobelow_skip ["XSS.SendResp"]
  def sitemap(conn, _params) do
    conn
    |> put_resp_content_type("application/xml")
    |> put_resp_header("cache-control", @cache_control)
    |> send_resp(:ok, SeoXML.sitemap())
  end

  # The body is the Markdown from `LlmsTxt.body/0`, built only from the docs
  # allow-list, the runtime list, the plan prices and fixed public routes,
  # sent as text/plain, not HTML.
  @spec llms_txt(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def llms_txt(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("cache-control", @cache_control)
    |> send_resp(:ok, LlmsTxt.body())
  end

  # The body is the Atom feed from `ChangelogFeed.atom/1`, which escapes every
  # value, release notes included, sent as application/atom+xml, not HTML.
  @spec changelog_feed(Plug.Conn.t(), map()) :: Plug.Conn.t()
  # sobelow_skip ["XSS.SendResp"]
  def changelog_feed(conn, _params) do
    conn
    |> put_resp_content_type("application/atom+xml")
    |> put_resp_header("cache-control", @cache_control)
    |> send_resp(:ok, ChangelogFeed.atom(PageHTML.changelog_releases()))
  end

  # conn.host is always a binary and never carries the port. Host names are
  # case-insensitive, and the match is exact, so a look-alike such as
  # `localhost.example.com` is another host.
  defp indexable?(host) do
    indexable_deployment?() and String.downcase(host) == String.downcase(Endpoint.host())
  end

  # Read at request time so a test can turn it off; anything but `true` is off.
  defp indexable_deployment? do
    :kanban |> Application.get_env(__MODULE__, []) |> Keyword.get(:indexable) == true
  end
end
