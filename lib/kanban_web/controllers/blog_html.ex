defmodule KanbanWeb.BlogHTML do
  @moduledoc """
  Templates for `KanbanWeb.BlogController` (W2951). See the `blog_html`
  directory.
  """
  use KanbanWeb, :html

  import KanbanWeb.SeoComponents, only: [structured_data: 1]

  alias KanbanWeb.Blog
  alias KanbanWeb.SeoComponents

  embed_templates "blog_html/*"

  @doc """
  The author of `post`. `KanbanWeb.Blog` fails the build on a post whose
  author is unknown, so every published post has one.
  """
  @spec post_author(Blog.post()) :: KanbanWeb.Blog.Authors.author()
  def post_author(post) do
    {:ok, author} = Blog.author(post.author)
    author
  end

  @doc """
  The schema.org `BlogPosting` a post page renders as JSON-LD: the headline,
  the description, the ISO 8601 publication date, the author's name and the
  post's canonical URL. Every value comes from the compile-time post catalog,
  never from request data.
  """
  @spec post_structured_data(Blog.post(), KanbanWeb.Blog.Authors.author()) :: map()
  def post_structured_data(post, author) do
    %{
      "@context" => "https://schema.org",
      "@type" => "BlogPosting",
      "headline" => post.title,
      "description" => post.description,
      "datePublished" => DateTime.to_iso8601(post.date),
      "author" => %{"@type" => "Person", "name" => author.name},
      "url" => SeoComponents.canonical_url("/blog/" <> post.slug),
      "inLanguage" => "en"
    }
  end
end
