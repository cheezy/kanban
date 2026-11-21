defmodule KanbanWeb.Changelog do
  @moduledoc """
  Parses the hand-written changelog body in `priv/changelog/body.html` into
  the HTML the `/changelog` page renders and the list of releases the
  `/changelog/feed.xml` Atom feed is built from (W2896).

  `KanbanWeb.PageHTML` parses the file once, at compile time, so the page and
  the feed read the same source and can never list different releases.

  The body is a run of `<section class="mb-10">` elements, newest first, each
  opening with an `<h2>` that reads `[Unreleased]` or `[X.Y.Z] - YYYY-MM-DD`.
  `parse/1` gives every section an `id` the feed links to:

    * `[X.Y.Z] - YYYY-MM-DD` gets `release-X-Y-Z` and becomes a release.
    * `[X.Y.Z]` with no date gets `release-X-Y-Z` but is not a release, because
      an Atom entry needs a date.
    * `[Unreleased]` gets `unreleased` and is not a release: it has not
      shipped.
    * Any other heading keeps its section as it is, with no `id`.

  A new release is written by hand as before; its `id` is added here, so the
  file never carries one.
  """

  @section_open ~s(<section class="mb-10">)
  @heading ~r/\A\s*<h2\b[^>]*>(.*?)<\/h2>/s
  @release_heading ~r/\A\[(Unreleased|\d+\.\d+\.\d+)\](?: - (\d{4}-\d{2}-\d{2}))?\z/
  @inline_tag ~r/<[^>]*>/

  @type release :: %{
          version: String.t(),
          date: Date.t(),
          anchor: String.t(),
          notes: String.t()
        }

  @doc """
  Parses a changelog body.

  Returns the body with an `id` on each recognised section, and the dated
  releases in the order they appear. Each release carries its `version`, its
  `date`, its `anchor` (the section `id`) and its `notes`, the section's HTML
  after the heading, exactly as written.
  """
  @spec parse(String.t()) :: %{body: String.t(), releases: [release()]}
  def parse(html) when is_binary(html) do
    [lead | sections] = String.split(html, @section_open)
    parsed = Enum.map(sections, &parse_section/1)

    %{body: body(lead, parsed), releases: releases(parsed)}
  end

  @doc """
  The section `id` for a version: `"3.2.0"` becomes `"release-3-2-0"`.
  """
  @spec anchor(String.t()) :: String.t()
  def anchor(version) when is_binary(version), do: "release-" <> String.replace(version, ".", "-")

  defp body(lead, parsed) do
    IO.iodata_to_binary([lead | Enum.map(parsed, fn {anchor, raw, _} -> [open(anchor), raw] end)])
  end

  defp releases(parsed), do: for({_, _, release} <- parsed, release, do: release)

  defp parse_section(raw) do
    case Regex.run(@heading, raw) do
      [heading, text] ->
        rest = binary_part(raw, byte_size(heading), byte_size(raw) - byte_size(heading))
        classify(heading_text(text), rest, raw)

      nil ->
        {nil, raw, nil}
    end
  end

  defp classify(text, rest, raw) do
    case Regex.run(@release_heading, text) do
      ["[Unreleased]" | _] -> {"unreleased", raw, nil}
      [_, version, date] -> {anchor(version), raw, release(version, date, rest)}
      [_, version] -> {anchor(version), raw, nil}
      nil -> {nil, raw, nil}
    end
  end

  defp release(version, date, rest) do
    case Date.from_iso8601(date) do
      {:ok, date} -> %{version: version, date: date, anchor: anchor(version), notes: notes(rest)}
      {:error, _reason} -> nil
    end
  end

  # Sections never nest, so the section ends at the first closing tag.
  defp notes(rest), do: rest |> String.split("</section>", parts: 2) |> hd() |> String.trim()

  defp heading_text(text) do
    @inline_tag |> Regex.replace(text, "") |> String.split() |> Enum.join(" ")
  end

  defp open(nil), do: @section_open
  defp open(anchor), do: ~s(<section class="mb-10" id="#{anchor}">)
end
