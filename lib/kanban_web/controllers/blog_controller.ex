defmodule KanbanWeb.BlogController do
  @moduledoc """
  Serves the blog experiment (W2951): `/blog` lists the posts and
  `/blog/:slug` renders one, under the marketing layout.

  Both answer 404 unless the `:blog` feature flag is on for the visitor's
  current scope, so the experiment cannot be found by guessing the URL; a
  signed-out visitor follows the everyone gate. Every post comes from the
  compile-time catalog in `KanbanWeb.Blog`, so nothing is read from disk or
  the database per request, and a slug is only ever looked up with
  `KanbanWeb.Blog.fetch/1`.
  """
  use KanbanWeb, :controller

  alias Kanban.FeatureFlags
  alias KanbanWeb.Blog

  plug :require_blog_flag
  plug :put_root_layout, [html: {KanbanWeb.Layouts, :marketing}] when action in [:index, :show]

  def index(conn, _params) do
    render(conn, :index,
      posts: Blog.posts(),
      page_title: gettext("Stride blog"),
      meta_description:
        gettext(
          "Posts from the Stride team on AI coding agents, software delivery and what it costs to build with AI."
        )
    )
  end

  def show(conn, %{"slug" => slug}) do
    case Blog.fetch(slug) do
      {:ok, post} ->
        {:ok, author} = Blog.author(post.author)

        render(conn, :show,
          post: post,
          author: author,
          page_title: post.title,
          meta_description: post.description
        )

      :error ->
        not_found(conn)
    end
  end

  # Answers 404 rather than redirecting when the flag is off, so the URL
  # reveals nothing about the experiment.
  defp require_blog_flag(conn, _opts) do
    if FeatureFlags.enabled?(conn.assigns[:current_scope], :blog) do
      conn
    else
      conn |> not_found() |> halt()
    end
  end

  # ErrorHTML renders a whole document, so the marketing root layout is
  # switched off for it. The scope's :put_noindex header is dropped so the
  # 404 matches every other public 404 and does not reveal the hidden blog.
  defp not_found(conn) do
    conn
    |> delete_resp_header("x-robots-tag")
    |> put_status(:not_found)
    |> put_root_layout(false)
    |> put_view(html: KanbanWeb.ErrorHTML)
    |> render(:"404")
  end
end
