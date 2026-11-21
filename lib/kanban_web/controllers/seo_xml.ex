defmodule KanbanWeb.SeoXML do
  @moduledoc """
  Builds the body of `/sitemap.xml` (W2891), which `KanbanWeb.SeoController`
  serves.

  The sitemap lists the public marketing pages, the published guides
  (`KanbanWeb.Docs.sitemap_paths/0`) and the agent runtime pages
  (`KanbanWeb.Integrations.sitemap_paths/0`) in `public_paths/0`, and one
  `/resources/<id>` page per how-to in
  `KanbanWeb.ResourcesLive.HowToData.all_how_tos/0`. Every `<loc>` is built by
  `KanbanWeb.SeoComponents.canonical_url/1`, so it is absolute and matches the
  canonical link the page itself renders.

  `/users/register` and `/users/log-in` stay indexable (they carry no
  noindex), but they are account pages rather than content, so the sitemap
  leaves them out. Token, account, board, admin and API paths are never
  listed. `robots.txt` does not disallow the token, account, board and admin
  pages, because crawlers see their noindex only by fetching them; it
  disallows `/api/`, which serves no pages.

  A new public page needs adding to `public_paths/0`. The controller test
  derives the PageController pages from the router and fails until a new one
  is listed; `/issue` and `/resources` are LiveView pages and are checked by
  name, so a new public LiveView page must be added here by hand.
  """

  alias KanbanWeb.Docs
  alias KanbanWeb.Integrations
  alias KanbanWeb.ResourcesLive.HowToData
  alias KanbanWeb.SeoComponents

  @public_paths ~w(
    /
    /about
    /acceptable-use
    /HitMe
    /pricing
    /privacy
    /product
    /security
    /tango
    /terms
    /workflows
    /changelog
    /issue
    /resources
    /demo
  )

  @doc """
  The public pages the sitemap lists, apart from the how-tos: the marketing
  pages, then `/docs` and every published guide, then `/integrations` and
  every runtime page.
  """
  @spec public_paths() :: [String.t()]
  def public_paths, do: @public_paths ++ Docs.sitemap_paths() ++ Integrations.sitemap_paths()

  @doc """
  Renders the sitemap for `how_tos`, which defaults to every how-to.

  Each how-to needs only an `:id`. Every `<loc>` is XML-escaped, so no id can
  inject markup.
  """
  @spec sitemap([%{required(:id) => String.t()}]) :: String.t()
  def sitemap(how_tos \\ HowToData.all_how_tos()) do
    urls =
      how_tos
      |> paths()
      |> Enum.map(&SeoComponents.canonical_url/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&["  <url><loc>", escape(&1), "</loc></url>\n"])

    IO.iodata_to_binary([
      ~s(<?xml version="1.0" encoding="UTF-8"?>\n),
      ~s(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n),
      urls,
      "</urlset>\n"
    ])
  end

  defp paths(how_tos), do: public_paths() ++ Enum.map(how_tos, &("/resources/" <> &1.id))

  # Plug.HTML escapes & < > " and ', which covers every character XML
  # reserves in text.
  defp escape(value), do: Plug.HTML.html_escape(value)
end
