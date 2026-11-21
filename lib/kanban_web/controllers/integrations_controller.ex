defmodule KanbanWeb.IntegrationsController do
  @moduledoc """
  Serves the agent runtime pages (W2899): `/integrations` lists every runtime
  Stride has a plugin for and `/integrations/:runtime` shows one, with its
  install steps. Both are public pages under the marketing layout.

  A runtime is only looked up in the `KanbanWeb.Integrations` list; an unknown
  one answers 404.
  """
  use KanbanWeb, :controller

  alias KanbanWeb.Integrations

  plug :put_root_layout, [html: {KanbanWeb.Layouts, :marketing}] when action in [:index, :show]

  def index(conn, _params) do
    render(conn, :index,
      runtimes: Integrations.all(),
      page_title: gettext("Stride integrations for AI coding agents"),
      meta_description:
        gettext(
          "Stride plugins for Claude Code, Codex CLI, Gemini CLI, GitHub Copilot, OpenCode and Pi: what each one adds and the command that installs it."
        )
    )
  end

  def show(conn, %{"runtime" => slug}) do
    case Integrations.fetch(slug) do
      {:ok, runtime} ->
        render(conn, :show,
          runtime: runtime,
          page_title: Integrations.page_title(runtime),
          meta_description: Integrations.meta_description(runtime)
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
