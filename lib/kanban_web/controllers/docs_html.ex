defmodule KanbanWeb.DocsHTML do
  @moduledoc """
  Templates for `KanbanWeb.DocsController`. See the `docs_html` directory.
  """
  use KanbanWeb, :html

  alias KanbanWeb.Docs

  embed_templates "docs_html/*"

  @doc """
  The GitHub URL of a page's source file.
  """
  def github_source_url(page), do: Docs.github_source_url(page)
end
