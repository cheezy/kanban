defmodule KanbanWeb.Docs.Renderer do
  @moduledoc """
  Renders one published guide's markdown to HTML (W2898).

  The markdown is parsed with MDEx, every link is passed through
  `KanbanWeb.Docs.Links.rewrite/4`, and the document is rendered with raw HTML
  escaped (`render: [escape: true]`), never with `unsafe: true`, so a guide can
  never inject markup or script into the page. Tables, autolinks and
  strikethrough are on, as on GitHub, and every heading gets the id GitHub
  gives it (`header_id_prefix: ""`), so `#anchor` links keep working.

  `KanbanWeb.Docs` calls `render/4` at compile time. It raises, failing the
  build rather than publishing a broken page, when a guide has no level-one
  heading or contains an image, which the site's Content Security Policy would
  block.
  """

  alias KanbanWeb.Docs.Links

  @options [
    extension: [table: true, autolink: true, strikethrough: true, header_id_prefix: ""],
    render: [escape: true]
  ]

  @type toc_entry :: %{id: String.t(), text: String.t()}
  @type rendered :: %{html: String.t(), title: String.t(), toc: [toc_entry()]}

  @doc """
  The MDEx options every guide is parsed and rendered with.
  """
  @spec options() :: keyword()
  def options, do: @options

  @doc """
  Renders `markdown`, the guide at repository path `source`, with links
  rewritten against `published` and `directories` (see
  `KanbanWeb.Docs.Links`).

  Returns the HTML, the plain text of the first level-one heading as the
  title, and one table-of-contents entry per section: per level-two heading,
  or per level-three heading when the guide has fewer than two level-two
  headings.
  """
  @spec render(String.t(), String.t(), Links.published(), Links.directories()) :: rendered()
  def render(markdown, source, published, directories \\ MapSet.new()) do
    document =
      markdown
      |> MDEx.parse_document!(@options)
      |> MDEx.traverse_and_update(&rewrite_node(&1, source, {published, directories}))

    html = MDEx.to_html!(document, @options)

    %{html: html, title: title!(document, source), toc: toc!(document, html, source)}
  end

  defp rewrite_node(%MDEx.Link{url: url} = link, source, {published, directories}) do
    case Links.rewrite(url, source, published, directories) do
      {:ok, rewritten} -> %{link | url: rewritten}
      :drop -> %MDEx.Text{literal: plain_text(link)}
    end
  end

  defp rewrite_node(%MDEx.Image{url: url}, source, _repo) do
    raise ArgumentError,
          "#{source} contains an image (#{url}); the docs pages do not publish images"
  end

  defp rewrite_node(node, _source, _repo), do: node

  defp title!(document, source) do
    case document |> headings() |> Enum.find(&(&1.level == 1)) do
      nil -> raise ArgumentError, "#{source} has no level-one heading to use as its title"
      heading -> plain_text(heading)
    end
  end

  # The guide's sections: its level-two headings, or its level-three headings
  # when it has fewer than two level-two headings (a guide written as one h2
  # with h3 sections), in document order and paired with the ids the renderer
  # gave them. Both lists come from the same document, so a count mismatch
  # means the renderer changed how it writes headings.
  defp toc!(document, html, source) do
    all = headings(document)
    level = toc_level(all)
    texts = for %{level: ^level} = heading <- all, do: plain_text(heading)
    ids = heading_ids(html, level)

    if length(texts) != length(ids) do
      raise ArgumentError,
            "#{source}: found #{length(texts)} h#{level} headings but #{length(ids)} ids"
    end

    ids
    |> Enum.zip(texts)
    |> Enum.map(fn {id, text} -> %{id: id, text: text} end)
  end

  # The ids the renderer gave the level-`level` headings, in document order.
  defp heading_ids(html, level) do
    ~r/<h#{level} id="([^"]*)"/
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
  end

  defp toc_level(headings) do
    if Enum.count(headings, &(&1.level == 2)) >= 2, do: 2, else: 3
  end

  defp headings(node), do: node |> children() |> Enum.flat_map(&collect_headings/1)

  defp collect_headings(%MDEx.Heading{} = heading), do: [heading]
  defp collect_headings(node), do: headings(node)

  defp plain_text(%{literal: literal}) when is_binary(literal), do: literal

  defp plain_text(node), do: node |> children() |> Enum.map_join(&plain_text/1)

  defp children(%{nodes: nodes}) when is_list(nodes), do: nodes
  defp children(_node), do: []
end
