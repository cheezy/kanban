defmodule KanbanWeb.CompareController do
  @moduledoc """
  Serves the comparison pages (W2901): `/compare` lists every comparison and
  `/compare/:competitor` sets Stride against one other product for work done
  by AI coding agents. Both are public pages under the marketing layout, and
  the footer links the index.

  A competitor is only looked up in the `KanbanWeb.Comparisons` list; an
  unknown one answers 404.
  """
  use KanbanWeb, :controller

  alias KanbanWeb.Comparisons

  plug :put_root_layout, [html: {KanbanWeb.Layouts, :marketing}] when action in [:index, :show]

  def index(conn, _params) do
    render(conn, :index,
      comparisons: Comparisons.all(),
      page_title: gettext("Stride compared with GitHub Projects, Linear and Jira"),
      meta_description:
        gettext(
          "How Stride compares with GitHub Projects, Linear and Jira for work done by AI coding agents, with a source for every claim about the other product."
        )
    )
  end

  def show(conn, %{"competitor" => slug}) do
    case Comparisons.fetch(slug) do
      {:ok, comparison} ->
        render(conn, :show,
          comparison: comparison,
          stride_fits: Comparisons.stride_fits(),
          page_title: Comparisons.page_title(comparison),
          meta_description: Comparisons.meta_description(comparison)
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
