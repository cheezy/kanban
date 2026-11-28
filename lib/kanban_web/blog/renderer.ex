defmodule KanbanWeb.Blog.Renderer do
  @moduledoc """
  Renders one blog post's markdown body to HTML (W2950).

  The options match `KanbanWeb.Docs.Renderer`: raw HTML is escaped
  (`render: [escape: true]`, never `unsafe: true`), tables, autolinks and
  strikethrough are on, and every heading gets an id. That renderer is not
  reused, because it requires a level-one heading and rewrites links against
  the docs allow-list; a post's title comes from its front matter instead.

  Every link and image is checked while the document is walked, and anything
  unsafe raises `ArgumentError` naming the post, so a bad post fails the
  build:

    * A link must be `http`, `https` or `mailto`. A site-relative link to
      another Hugo post (`/post/<slug>/`) is rewritten to that post on
      cheezyworld.ca, so the copied body stays unchanged; anything else
      (`javascript:`, `data:`, a relative path) raises.
    * An image must be `/img/<file>`, which is rewritten to
      `/images/blog/<file>`, and `<file>` must exist under
      `priv/static/images/blog/` and the image must have alt text. Any other
      source (an external URL, a `data:` URI) raises: the blog serves images
      only from the site itself, so a post can never load third-party
      content or need the Content Security Policy widened.
  """

  @options [
    extension: [table: true, autolink: true, strikethrough: true, header_id_prefix: ""],
    render: [escape: true]
  ]

  @image_root Path.expand("../../../priv/static/images/blog", __DIR__)
  @hugo_site "https://cheezyworld.ca"
  @link_schemes ~w(http https mailto)

  @doc """
  The MDEx options every post is parsed and rendered with.
  """
  @spec options() :: keyword()
  def options, do: @options

  @doc """
  Renders `markdown`, the body of the post at `path`, to HTML.

  `opts[:image_root]` is the directory images are checked against; it
  defaults to `priv/static/images/blog`.
  """
  @spec render!(String.t(), String.t(), keyword()) :: String.t()
  def render!(markdown, path, opts \\ []) do
    image_root = Keyword.get(opts, :image_root, @image_root)

    markdown
    |> MDEx.parse_document!(@options)
    |> MDEx.traverse_and_update(&check_node(&1, path, image_root))
    |> MDEx.to_html!(@options)
  end

  defp check_node(%MDEx.Link{url: url} = link, path, _image_root),
    do: %{link | url: link_url!(url, path)}

  defp check_node(%MDEx.Image{url: url} = image, path, image_root),
    do: %{image | url: image_url!(image, url, path, image_root)}

  defp check_node(node, _path, _image_root), do: node

  defp link_url!(url, path) do
    cond do
      allowed_scheme?(url) -> url
      Regex.match?(~r{\A/post/[a-z0-9_-]+/?\z}, url) -> @hugo_site <> url
      true -> raise ArgumentError, "#{path}: link #{inspect(url)} is not http(s) or mailto"
    end
  end

  defp allowed_scheme?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} when is_binary(scheme) -> String.downcase(scheme) in @link_schemes
      _uri -> false
    end
  end

  defp image_url!(image, url, path, image_root) do
    file = image_file!(url, path)

    # The file name matched a strict pattern with no directory part above.
    unless image_root |> Path.join(file) |> File.regular?() do
      raise ArgumentError,
            "#{path}: image #{inspect(url)} is missing from priv/static/images/blog/"
    end

    if image |> plain_text() |> String.trim() == "" do
      raise ArgumentError, "#{path}: image #{inspect(url)} has no alt text"
    end

    "/images/blog/" <> file
  end

  defp image_file!(url, path) do
    case Regex.run(~r{\A/img/([A-Za-z0-9_-]+\.(?:png|jpe?g|gif|webp))\z}, url,
           capture: :all_but_first
         ) do
      [file] ->
        file

      nil ->
        raise ArgumentError,
              "#{path}: image #{inspect(url)} is not a local /img/ image; only images served by this site are allowed"
    end
  end

  defp plain_text(%{literal: literal}) when is_binary(literal), do: literal
  defp plain_text(%{nodes: nodes}) when is_list(nodes), do: Enum.map_join(nodes, &plain_text/1)
  defp plain_text(_node), do: ""
end
