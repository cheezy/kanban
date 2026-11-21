defmodule KanbanWeb.Docs.Links do
  @moduledoc """
  Rewrites the links in a published guide (W2898) so they work on the site.

  The guides are written for GitHub, so their links are relative to the file
  they sit in (`docs/doc-link-contract.md`). On the site a relative link has to
  go somewhere real, so `rewrite/4` maps each one:

    * `#anchor` stays as it is: the renderer gives every heading the id GitHub
      gives it.
    * `http`, `https` and `mailto` links stay as they are.
    * A link to another published guide becomes `/docs/<slug>`, keeping its
      `?query` and `#anchor`.
    * A link to any other file or directory in the repository becomes its
      GitHub URL, keeping its `?query` and `#anchor`: `tree` for a path in
      `directories`, `blob` for anything else. Whether a path is a directory
      is never guessed from its name (`Makefile` is a file, `.github` a
      directory), because the repository is not there to look at when the
      release is built; `KanbanWeb.Docs` passes the directories its guides
      link to, and `test/kanban_web/controllers/docs_controller_test.exs`
      fails when a `blob` or `tree` URL names no such file or directory.
    * A link with no path, such as `?tab=1`, stays as it is.
    * Anything else is refused with `:drop`: another scheme (`javascript:`,
      `data:`), a scheme-relative `//host` link, or a path that climbs above
      the repository root. The renderer keeps the link's text and drops the
      link.

  It reads no file and builds no file path, so it works where the repository's
  `docs/` directory is absent, as in the release image.
  """

  alias KanbanWeb.MarketingClosing

  @kept_schemes ~w(http https mailto)

  @typedoc "Repository path of a published guide (or directory) to its slug."
  @type published :: %{String.t() => String.t()}

  @typedoc "Repository paths, with no trailing slash, that are directories."
  @type directories :: MapSet.t(String.t())

  @doc """
  Rewrites `url`, a link found in the guide at repository path `from`.

  `published` maps each published guide's repository path to its slug, and
  `directories` holds the unpublished repository paths that are directories,
  which link to GitHub's `tree` view rather than `blob`.

  Returns `{:ok, url}` with the link to render, or `:drop` when the link must
  not be rendered as a link.
  """
  @spec rewrite(String.t(), String.t(), published(), directories()) ::
          {:ok, String.t()} | :drop
  def rewrite(url, from, published, directories \\ MapSet.new())

  def rewrite("#" <> _ = url, _from, _published, _directories), do: {:ok, url}

  def rewrite(url, from, published, directories) when is_binary(url) do
    url |> URI.parse() |> rewrite_uri(url, from, {published, directories})
  end

  defp rewrite_uri(%URI{scheme: scheme}, url, _from, _repo) when scheme in @kept_schemes,
    do: {:ok, url}

  defp rewrite_uri(%URI{scheme: nil, host: nil} = uri, url, from, repo),
    do: rewrite_relative(uri, url, from, repo)

  defp rewrite_uri(_uri, _url, _from, _repo), do: :drop

  defp rewrite_relative(%URI{path: path}, url, _from, _repo) when path in [nil, ""],
    do: {:ok, url}

  defp rewrite_relative(%URI{path: path} = uri, _url, from, repo) do
    case resolve(URI.decode(path), from) do
      {:ok, target} -> {:ok, target_url(target, repo) <> query(uri) <> anchor(uri)}
      :error -> :drop
    end
  end

  # Resolves a relative path against the directory of the linking file, or
  # against the repository root when it starts with "/". ".." past the root is
  # refused.
  defp resolve("/" <> path, _from), do: normalise(String.split(path, "/"))

  defp resolve(path, from) do
    base = from |> Path.dirname() |> String.split("/")
    normalise(base ++ String.split(path, "/"))
  end

  defp normalise(segments) do
    segments
    |> Enum.reduce_while([], &step/2)
    |> case do
      :error -> :error
      reversed -> {:ok, reversed |> Enum.reverse() |> Enum.join("/")}
    end
  end

  defp step(segment, acc) when segment in ["", "."], do: {:cont, acc}
  defp step("..", []), do: {:halt, :error}
  defp step("..", [_ | rest]), do: {:cont, rest}
  defp step(segment, acc), do: {:cont, [segment | acc]}

  defp target_url(target, {published, directories}) do
    case Map.fetch(published, target) do
      {:ok, slug} -> "/docs/" <> slug
      :error -> github_url(target, directories)
    end
  end

  defp github_url("", _directories), do: MarketingClosing.github_url()

  defp github_url(target, directories) do
    kind = if MapSet.member?(directories, target), do: "tree", else: "blob"
    MarketingClosing.github_url() <> "/" <> kind <> "/main/" <> URI.encode(target)
  end

  defp query(%URI{query: nil}), do: ""
  defp query(%URI{query: query}), do: "?" <> query

  defp anchor(%URI{fragment: nil}), do: ""
  defp anchor(%URI{fragment: fragment}), do: "#" <> fragment
end
