defmodule KanbanWeb.BlogHTMLTest do
  @moduledoc """
  The blog page helpers (W2951): each post's author and its schema.org
  `BlogPosting` structured data.
  """
  use ExUnit.Case, async: true

  alias KanbanWeb.Blog
  alias KanbanWeb.BlogHTML
  alias KanbanWeb.SeoComponents

  test "post_author/1 returns the post's author" do
    for post <- Blog.posts() do
      assert {:ok, author} = Blog.author(post.author)
      assert BlogHTML.post_author(post) == author
    end
  end

  test "BlogPosting structured data has headline, ISO 8601 datePublished, author and url" do
    for post <- Blog.posts() do
      author = BlogHTML.post_author(post)
      data = BlogHTML.post_structured_data(post, author)

      assert data["@context"] == "https://schema.org"
      assert data["@type"] == "BlogPosting"
      assert data["headline"] == post.title
      assert data["description"] == post.description
      assert data["datePublished"] == DateTime.to_iso8601(post.date)
      assert data["datePublished"] =~ ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/
      assert {:ok, published, 0} = DateTime.from_iso8601(data["datePublished"])
      assert DateTime.compare(published, post.date) == :eq
      assert data["author"] == %{"@type" => "Person", "name" => author.name}
      assert data["url"] == SeoComponents.canonical_url("/blog/" <> post.slug)
      assert data["inLanguage"] == "en"
    end
  end

  test "the structured data encodes to JSON-LD" do
    [post | _] = Blog.posts()
    data = BlogHTML.post_structured_data(post, BlogHTML.post_author(post))

    assert data |> SeoComponents.encode_json_ld() |> Jason.decode!() == data
  end
end
