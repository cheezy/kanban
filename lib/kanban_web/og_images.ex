defmodule KanbanWeb.OgImages do
  @moduledoc """
  The per-page link-preview images (W2904): one 1200x630 PNG for every how-to,
  every `/docs` page and every `/integrations` runtime, showing the page's
  title on the Stride background.

  `pages/0` lists every page that has an image, `svg/1` fills
  `priv/og/template.svg` with one page's label and title, and `path/2` gives
  the static path a page assigns as `:og_image`. The PNGs are generated once by
  `mix kanban.og_images` and committed under `priv/static/images/og/`; nothing
  here runs at request time apart from `path/2`, which only checks a slug
  against the three allow-lists.

  Titles and labels are English in every locale: one image per page, never
  one per language. `docs/seo.md` ("The Open Graph image") says when to rerun
  the task.
  """

  alias KanbanWeb.Docs
  alias KanbanWeb.Integrations
  alias KanbanWeb.ResourcesLive.HowToData

  # Read at compile time so the template ships inside the beam.
  @template_path Path.expand("../../priv/og/template.svg", __DIR__)
  @external_resource @template_path
  # sobelow_skip ["Traversal.FileModule"]
  @template File.read!(@template_path)

  @line_budget 26
  @max_lines 3
  @line_height 78

  @dirs %{how_to: "how-to", docs: "docs", integrations: "integrations"}

  @type kind :: :how_to | :docs | :integrations
  @type page :: %{
          kind: kind(),
          slug: String.t(),
          title: String.t(),
          label: String.t(),
          path: String.t()
        }

  @doc """
  Every page that has its own image, how-tos first, then docs pages, then
  integration runtimes.
  """
  @spec pages() :: [page()]
  def pages do
    how_to_pages() ++ docs_pages() ++ integration_pages()
  end

  @doc """
  The static path of a page's image, `/images/og/<kind>/<slug>.png`, or `nil`
  when the slug is not in that kind's allow-list.
  """
  @spec path(kind() | term(), term()) :: String.t() | nil
  def path(kind, slug) when is_map_key(@dirs, kind) and is_binary(slug) do
    if known?(kind, slug), do: image_path(kind, slug)
  end

  def path(_kind, _slug), do: nil

  @doc """
  The SVG for one page: the template with its label and its escaped title,
  wrapped onto at most three lines.
  """
  @spec svg(%{required(:title) => String.t(), required(:label) => String.t()}) :: String.t()
  def svg(%{title: title, label: label}) do
    # The title goes in last, so text in a title can never form a placeholder.
    @template
    |> String.replace("{{LABEL}}", escape(String.upcase(label)))
    |> String.replace("{{TITLE_LINES}}", title_tspans(title))
  end

  @doc """
  Splits a title into at most three lines of up to #{@line_budget} characters.
  A word longer than a line breaks before each `/`, then anywhere; a title that
  needs more than three lines ends its third with an ellipsis.
  """
  @spec title_lines(String.t()) :: [String.t()]
  def title_lines(title) do
    title
    |> String.split()
    |> Enum.flat_map(&pieces/1)
    |> Enum.reduce([], &place/2)
    |> Enum.reverse()
    |> clamp()
  end

  defp how_to_pages do
    Enum.map(HowToData.all_how_tos(), &page(:how_to, &1.id, &1.title, "How-to guide"))
  end

  defp docs_pages do
    Enum.map(Docs.pages(), &page(:docs, &1.slug, &1.title, docs_label(&1.group)))
  end

  defp integration_pages do
    Enum.map(
      Integrations.all(),
      &page(:integrations, &1.slug, "Stride for #{&1.name}", "Integration")
    )
  end

  defp docs_label(:api), do: "API reference"
  defp docs_label(_group), do: "Documentation"

  defp page(kind, slug, title, label) do
    %{kind: kind, slug: slug, title: title, label: label, path: image_path(kind, slug)}
  end

  defp image_path(kind, slug), do: "/images/og/#{Map.fetch!(@dirs, kind)}/#{slug}.png"

  defp known?(:how_to, slug), do: match?({:ok, _}, HowToData.get_how_to(slug))
  defp known?(:docs, slug), do: match?({:ok, _}, Docs.fetch(slug))
  defp known?(:integrations, slug), do: match?({:ok, _}, Integrations.fetch(slug))

  defp title_tspans(title) do
    title
    |> title_lines()
    |> Enum.with_index()
    |> Enum.map_join(fn {line, index} ->
      dy = if index == 0, do: 0, else: @line_height
      ~s(<tspan x="80" dy="#{dy}">#{escape(line)}</tspan>)
    end)
  end

  defp escape(text) do
    text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end

  # A word that fits is one piece joined by a space. A longer one is split
  # before each "/" and then into line-sized chunks; its later pieces are glued
  # to the one before without a space.
  defp pieces(word) do
    if String.length(word) <= @line_budget do
      [{:space, word}]
    else
      word
      |> String.split(~r{(?=/)}, trim: true)
      |> Enum.flat_map(&chunks/1)
      |> mark_glue()
    end
  end

  defp chunks(part) do
    part
    |> String.graphemes()
    |> Enum.chunk_every(@line_budget)
    |> Enum.map(&Enum.join/1)
  end

  defp mark_glue([first | rest]), do: [{:space, first} | Enum.map(rest, &{:glue, &1})]

  defp place({_join, text}, []), do: [text]

  defp place({join, text}, [line | done]) do
    joined = if join == :space, do: line <> " " <> text, else: line <> text

    if String.length(joined) <= @line_budget,
      do: [joined | done],
      else: [text, line | done]
  end

  defp clamp(lines) when length(lines) <= @max_lines, do: lines

  defp clamp([first, second, third | _rest]) do
    last = third |> String.slice(0, @line_budget - 1) |> String.trim_trailing()
    [first, second, last <> "…"]
  end
end
