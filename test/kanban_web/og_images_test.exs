defmodule KanbanWeb.OgImagesTest do
  @moduledoc """
  The per-page link-preview images (W2904): the page list, the SVG each image
  is drawn from, the path a page assigns, and the committed PNGs themselves.
  """
  use ExUnit.Case, async: true

  alias KanbanWeb.Docs
  alias KanbanWeb.Integrations
  alias KanbanWeb.OgImages
  alias KanbanWeb.ResourcesLive.HowToData

  @static_root Path.expand("../../priv/static", __DIR__)
  @max_bytes 80 * 1024

  defp pages_of(kind), do: Enum.filter(OgImages.pages(), &(&1.kind == kind))

  defp tspans(svg), do: Regex.scan(~r{<tspan[^>]*>([^<]*)</tspan>}, svg, capture: :all_but_first)

  defp png_size(path) do
    case File.read(path) do
      {:ok, <<137, "PNG", 13, 10, 26, 10, _len::32, "IHDR", w::32, h::32, _rest::binary>>} ->
        {w, h}

      {:ok, _other} ->
        :not_a_png

      {:error, reason} ->
        reason
    end
  end

  describe "pages/0" do
    test "pages/0 lists one entry per how-to, docs guide and integration runtime with its title and image path" do
      how_tos = HowToData.all_how_tos()
      docs = Docs.pages()
      runtimes = Integrations.all()

      assert length(OgImages.pages()) == length(how_tos) + length(docs) + length(runtimes)

      assert pages_of(:how_to) |> Enum.map(&{&1.slug, &1.title}) ==
               Enum.map(how_tos, &{&1.id, &1.title})

      assert pages_of(:docs) |> Enum.map(&{&1.slug, &1.title}) ==
               Enum.map(docs, &{&1.slug, &1.title})

      assert pages_of(:integrations) |> Enum.map(& &1.slug) == Enum.map(runtimes, & &1.slug)

      for page <- OgImages.pages() do
        assert page.slug =~ ~r/\A[a-z0-9-]+\z/
        assert page.path == OgImages.path(page.kind, page.slug)
      end
    end

    test "titles and labels are English under any locale" do
      Gettext.put_locale(KanbanWeb.Gettext, "fr")
      on_exit(fn -> Gettext.put_locale(KanbanWeb.Gettext, "en") end)

      codex = :integrations |> pages_of() |> Enum.find(&(&1.slug == "codex"))
      assert codex.title == "Stride for Codex CLI"
      assert codex.label == "Integration"
      assert :how_to |> pages_of() |> Enum.all?(&(&1.label == "How-to guide"))

      assert pages_of(:docs) |> Enum.map(& &1.label) |> Enum.uniq() |> Enum.sort() ==
               ["API reference", "Documentation"]
    end
  end

  describe "svg/1" do
    test "svg/1 escapes an ampersand, angle bracket or quote in a title so it renders as text" do
      svg = OgImages.svg(%{title: ~s(A & B <script> "q" 'x'), label: "How-to <guide>"})

      assert svg =~ "A &amp; B"
      assert svg =~ "&lt;script&gt;"
      assert svg =~ "&quot;q&quot;"
      assert svg =~ "&#39;x&#39;"
      assert svg =~ "HOW-TO &lt;GUIDE&gt;"
      refute svg =~ "<script"
      refute svg =~ "{{"
    end

    test "a title cannot add a placeholder, an element or an external reference" do
      svg =
        OgImages.svg(%{
          title: ~s({{LABEL}} <image href="https://evil.test/x.png"/>),
          label: "Docs"
        })

      assert svg =~ "{{LABEL}}"
      refute svg =~ "<image"
      refute svg =~ ~s(href=")
    end

    test "svg/1 wraps a long title onto at most three lines and ends a longer one with an ellipsis" do
      long = String.duplicate("Stride keeps every agent busy ", 6)
      lines = OgImages.title_lines(long)

      assert length(lines) == 3
      assert List.last(lines) =~ ~r/…\z/
      assert Enum.all?(lines, &(String.length(&1) <= 26))
      assert length(tspans(OgImages.svg(%{title: long, label: "Docs"}))) == 3

      four = Enum.map_join(~w(a b c d), " ", &String.duplicate(&1, 20))
      assert [_, _, third] = OgImages.title_lines(four)
      assert third == String.duplicate("c", 20) <> "…"
    end

    test "a short title is one line and an exact three-line title has no ellipsis" do
      assert OgImages.title_lines("Archiving Tasks") == ["Archiving Tasks"]

      assert OgImages.title_lines("GET /api/tasks/:id/attachments/:attachment_id") ==
               ["GET /api/tasks/:id", "/attachments", "/:attachment_id"]
    end

    test "a word longer than a line with no slash is split into line-sized chunks" do
      word = String.duplicate("a", 30)
      assert OgImages.title_lines(word) == [String.duplicate("a", 26), "aaaa"]
    end

    test "every current title fits within three lines without an ellipsis" do
      for page <- OgImages.pages() do
        lines = OgImages.title_lines(page.title)
        assert length(lines) <= 3, page.title
        refute List.last(lines) =~ "…", page.title
      end
    end
  end

  describe "path/2" do
    test "path/2 returns /images/og/<kind>/<slug>.png for a known page and nil for an unknown slug" do
      assert OgImages.path(:how_to, "creating-your-first-board") ==
               "/images/og/how-to/creating-your-first-board.png"

      assert OgImages.path(:docs, "ai-workflow") == "/images/og/docs/ai-workflow.png"
      assert OgImages.path(:integrations, "codex") == "/images/og/integrations/codex.png"

      assert OgImages.path(:how_to, "no-such-guide") == nil
      assert OgImages.path(:docs, "../../etc/passwd") == nil
      assert OgImages.path(:integrations, "") == nil
      assert OgImages.path(:blog, "ai-workflow") == nil
      assert OgImages.path(:docs, nil) == nil
    end
  end

  describe "the developer guide" do
    test "docs/seo.md says when and how to regenerate the images" do
      guide = "../../docs/seo.md" |> Path.expand(__DIR__) |> File.read!()

      assert guide =~ "MIX_ENV=test mix kanban.og_images"
      assert guide =~ "brew install librsvg"
      assert guide =~ "Regenerate them\nafter adding, renaming or retitling"
    end
  end

  describe "committed images" do
    test "every how-to, docs guide and integration page has a committed 1200x630 PNG under priv/static/images/og" do
      wrong =
        for page <- OgImages.pages(),
            size = @static_root |> Path.join(page.path) |> png_size(),
            size != {1200, 630},
            do: {page.path, size}

      assert wrong == [],
             "run MIX_ENV=test mix kanban.og_images and commit the PNGs: #{inspect(wrong)}"
    end

    test "every committed image stays under 80 KB" do
      for page <- OgImages.pages() do
        %{size: size} = @static_root |> Path.join(page.path) |> File.stat!()
        assert size < @max_bytes, "#{page.path} is #{size} bytes"
      end
    end
  end
end
