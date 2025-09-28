defmodule KanbanWeb.PageController do
  use KanbanWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
