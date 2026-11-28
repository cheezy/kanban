defmodule KanbanWeb.Blog do
  @moduledoc """
  The blog's posts, compiled in from `priv/blog/posts/` (W2950).

  Every markdown file in that directory is read when this module compiles
  (see `KanbanWeb.Blog.Loader`), so a malformed post, an unknown author, an
  unsafe link or a missing image fails the build rather than reaching a page.
  Each file is an `@external_resource`, and `__mix_recompile__?/0` notices a
  post or image being added or removed, so the catalog never goes stale.

  `fetch/1` looks a slug up in a compile-time map and never turns its input
  into a file path. The blog is an experiment behind the `:blog` feature flag.
  """

  alias KanbanWeb.Blog.Authors
  alias KanbanWeb.Blog.Loader

  @type post :: Loader.post()

  @posts_dir Path.expand("../../priv/blog/posts", __DIR__)
  @images_dir Path.expand("../../priv/static/images/blog", __DIR__)

  for file <- Loader.post_files(@posts_dir) do
    @external_resource file
  end

  @listing_hash Loader.listing_hash(@posts_dir, @images_dir)
  @posts Loader.load_posts(@posts_dir)
  @by_slug Map.new(@posts, &{&1.slug, &1})

  @doc false
  def __mix_recompile__?, do: Loader.listing_hash(@posts_dir, @images_dir) != @listing_hash

  @doc """
  Every published post, newest first. Drafts are left out.
  """
  @spec posts() :: [post()]
  def posts, do: @posts

  @doc """
  Looks a post up by slug. Any other value, including a path, is `:error`.
  """
  @spec fetch(String.t()) :: {:ok, post()} | :error
  def fetch(slug), do: Map.fetch(@by_slug, slug)

  @doc """
  The published posts carrying `tag`, compared case-insensitively, newest
  first.
  """
  @spec posts_by_tag(String.t()) :: [post()]
  def posts_by_tag(tag) do
    wanted = String.downcase(tag)
    Enum.filter(@posts, fn post -> Enum.any?(post.tags, &(String.downcase(&1) == wanted)) end)
  end

  @doc """
  Looks an author up by id (see `KanbanWeb.Blog.Authors`).
  """
  @spec author(String.t()) :: {:ok, Authors.author()} | :error
  def author(id), do: Authors.fetch(id)
end
