defmodule KanbanWeb.DocsController do
  @moduledoc """
  Serves the published guides (W2898): `/docs` lists them and `/docs/:slug`
  renders one. Both are public pages under the marketing layout.

  A slug is only looked up in the `KanbanWeb.Docs` allow-list; an unknown one
  answers 404 and nothing is ever read from disk per request.
  """
  use KanbanWeb, :controller

  alias KanbanWeb.Docs
  alias KanbanWeb.OgImages

  plug :put_root_layout, [html: {KanbanWeb.Layouts, :marketing}] when action in [:index, :show]

  def index(conn, _params) do
    render(conn, :index,
      guides: Docs.pages(:guide),
      api_pages: Docs.pages(:api),
      page_title: gettext("Stride documentation"),
      meta_description:
        gettext(
          "Guides for running AI coding agents on Stride: getting started, the agent workflow, hooks, MCP, authentication and the REST API reference."
        )
    )
  end

  def show(conn, %{"slug" => slug}) do
    case Docs.fetch(slug) do
      {:ok, page} ->
        render(conn, :show,
          page: page,
          page_title: page.page_title,
          meta_description: page.description,
          og_image: OgImages.path(:docs, page.slug)
        )

      :error ->
        not_found(conn)
    end
  end

  # ErrorHTML renders a whole document, so the marketing root layout is
  # switched off for it.
  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> put_root_layout(false)
    |> put_view(html: KanbanWeb.ErrorHTML)
    |> render(:"404")
  end
end
