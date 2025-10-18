defmodule KanbanWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use KanbanWeb, :html

  import KanbanWeb.HomeComponents

  embed_templates "page_html/*"
end
