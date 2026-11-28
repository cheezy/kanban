defmodule KanbanWeb.Blog.Loader do
  @moduledoc """
  Loads the blog posts from a directory of markdown files (W2950).

  `KanbanWeb.Blog` calls `load_posts/2` at compile time; it lives in its own
  module because a module cannot call its own functions while it is being
  compiled, and so that tests can load a temporary directory.

  Each file is parsed with `KanbanWeb.Blog.FrontMatter`, its author is looked
  up in `KanbanWeb.Blog.Authors`, and its body is rendered with
  `KanbanWeb.Blog.Renderer`. Slugs must be unique across every file,
  drafts included. Drafts are then left out and the rest are sorted newest
  first. Every problem raises `ArgumentError` naming the file.
  """

  alias KanbanWeb.Blog.Authors
  alias KanbanWeb.Blog.FrontMatter
  alias KanbanWeb.Blog.Renderer

  @type post :: %{
          slug: String.t(),
          title: String.t(),
          date: DateTime.t(),
          tags: [String.t()],
          author: String.t(),
          description: String.t(),
          html: String.t()
        }

  @doc """
  The markdown files in `dir`, sorted by name. A missing directory has none.
  """
  @spec post_files(Path.t()) :: [Path.t()]
  def post_files(dir), do: dir |> Path.join("*.md") |> Path.wildcard() |> Enum.sort()

  @doc """
  Loads every post in `dir`, leaving out drafts, newest first.

  `opts` is passed on to `KanbanWeb.Blog.Renderer.render!/3`.
  """
  @spec load_posts(Path.t(), keyword()) :: [post()]
  def load_posts(dir, opts \\ []) do
    dir
    |> post_files()
    |> Enum.map(&load_post!(&1, opts))
    |> check_unique_slugs!()
    |> Enum.reject(& &1.draft)
    |> Enum.map(&Map.drop(&1, [:draft, :path]))
    |> Enum.sort_by(& &1.date, {:desc, DateTime})
  end

  @doc """
  A fingerprint of the post files and images on disk, so `KanbanWeb.Blog`
  recompiles when one is added or removed.
  """
  @spec listing_hash(Path.t(), Path.t()) :: integer()
  def listing_hash(posts_dir, images_dir) do
    images = images_dir |> Path.join("**") |> Path.wildcard() |> Enum.sort()
    :erlang.phash2({post_files(posts_dir), images})
  end

  # The path comes from a listing of the posts directory, never a request.
  # sobelow_skip ["Traversal.FileModule"]
  defp load_post!(file, opts) do
    path = Path.relative_to_cwd(file)

    {fields, body} = file |> File.read!() |> FrontMatter.parse!(path)

    if Authors.fetch(fields.author) == :error do
      raise ArgumentError, "#{path}: unknown author \"#{fields.author}\""
    end

    fields
    |> Map.put(:html, Renderer.render!(body, path, opts))
    |> Map.put(:path, path)
  end

  # Drafts are checked too, so publishing a draft can never collide with a
  # live post's URL. The error names every file that uses the slug.
  defp check_unique_slugs!(posts) do
    posts
    |> Enum.group_by(& &1.slug, & &1.path)
    |> Enum.sort()
    |> Enum.find(fn {_slug, paths} -> length(paths) > 1 end)
    |> case do
      nil ->
        posts

      {slug, paths} ->
        raise ArgumentError,
              "two posts share the slug \"#{slug}\": #{Enum.join(Enum.sort(paths), ", ")}"
    end
  end
end
