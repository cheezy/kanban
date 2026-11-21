defmodule KanbanWeb.ChangelogFeed do
  @moduledoc """
  Builds the Atom feed at `/changelog/feed.xml` (W2896), which
  `KanbanWeb.SeoController` serves.

  The feed has one entry per dated release in the changelog, from
  `KanbanWeb.PageHTML.changelog_releases/0`, the same parse the `/changelog`
  page renders. Each entry links to the release's section on `/changelog`
  (`/changelog#release-X-Y-Z`) and carries its release notes as
  `<content type="html">`.

  Every value is XML-escaped, so a note's markup reaches a feed reader as text
  for it to render, and no note can add elements to the feed itself. The notes
  lose their `class` and `style` attributes first: they style the page and
  mean nothing in a reader. Every URL is absolute, built by
  `KanbanWeb.SeoComponents.canonical_url/1` from the endpoint URL, never from
  the request. The feed's `xml:base` is the site root, so a relative link in a
  note resolves to this site in a reader.
  """
  use Gettext, backend: KanbanWeb.Gettext

  alias KanbanWeb.Changelog
  alias KanbanWeb.SeoComponents

  # An Atom feed needs an `updated` even when there is no release to take it
  # from. A fixed value keeps an empty feed the same on every request.
  @empty_updated "1970-01-01T00:00:00Z"

  @tag ~r/<[a-zA-Z][^>]*>/
  @presentational ~r/\s+(?:class|style)="[^"]*"/
  @before_close ~r/\s+>\z/

  @doc """
  Renders the feed for `releases`, as `KanbanWeb.Changelog.parse/1` returns
  them, newest first.
  """
  @spec atom([Changelog.release()]) :: String.t()
  def atom(releases) when is_list(releases) do
    page = SeoComponents.canonical_url("/changelog")

    IO.iodata_to_binary([
      ~s(<?xml version="1.0" encoding="UTF-8"?>\n),
      feed_open(),
      feed_head(releases, page),
      Enum.map(releases, &entry(&1, page)),
      "</feed>\n"
    ])
  end

  defp feed_open do
    [
      ~s(<feed xmlns="http://www.w3.org/2005/Atom" xml:lang="),
      escape(Gettext.get_locale(KanbanWeb.Gettext)),
      ~s(" xml:base="),
      escape(SeoComponents.canonical_url("/")),
      ~s(">\n)
    ]
  end

  defp feed_head(releases, page) do
    [
      element("id", page),
      element("title", gettext("Stride releases")),
      element("subtitle", gettext("Release notes for each new version of Stride.")),
      element("updated", updated(releases)),
      link("self", "application/atom+xml", SeoComponents.canonical_url("/changelog/feed.xml")),
      link("alternate", "text/html", page),
      "  <author><name>Stride</name></author>\n"
    ]
  end

  defp entry(release, page) do
    url = page <> "#" <> release.anchor
    date = timestamp(release.date)

    [
      "  <entry>\n",
      element("id", url, "    "),
      element("title", gettext("Stride %{version}", version: release.version), "    "),
      element("published", date, "    "),
      element("updated", date, "    "),
      link("alternate", "text/html", url, "    "),
      ~s(    <content type="html">),
      escape(strip_presentation(release.notes)),
      "</content>\n",
      "  </entry>\n"
    ]
  end

  defp updated([]), do: @empty_updated

  defp updated(releases),
    do: releases |> Enum.max_by(& &1.date, Date) |> Map.fetch!(:date) |> timestamp()

  defp timestamp(%Date{} = date), do: Date.to_iso8601(date) <> "T00:00:00Z"

  defp link(rel, type, href, indent \\ "  "),
    do: [indent, ~s(<link rel="), rel, ~s(" type="), type, ~s(" href="), escape(href), ~s("/>\n)]

  defp element(name, value, indent \\ "  "),
    do: [indent, "<", name, ">", escape(value), "</", name, ">\n"]

  # The page's tags put each attribute on its own line, so the space left before
  # the `>` once they are gone is dropped too.
  defp strip_presentation(html) do
    Regex.replace(@tag, html, fn tag ->
      @presentational |> Regex.replace(tag, "") |> String.replace(@before_close, ">")
    end)
  end

  # Plug.HTML escapes & < > " and ', which covers every character XML
  # reserves in text and attribute values.
  defp escape(value), do: Plug.HTML.html_escape(value)
end
