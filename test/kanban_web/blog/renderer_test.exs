defmodule KanbanWeb.Blog.RendererTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.Blog.Renderer

  @path "priv/blog/posts/example.md"

  defp raises(markdown, message, opts \\ []) do
    error = assert_raise ArgumentError, fn -> Renderer.render!(markdown, @path, opts) end
    assert error.message =~ @path
    assert error.message =~ message
  end

  describe "options/0" do
    test "escapes raw HTML and never renders it unsafely" do
      assert Renderer.options()[:render] == [escape: true]
    end
  end

  describe "render!/3" do
    test "escapes raw HTML" do
      html = Renderer.render!("Hello <script>alert(1)</script> world\n", @path)

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end

    test "gives headings ids, including one inside a blockquote" do
      html =
        Renderer.render!("## The Current Landscape\n\n> ### Executive summary\n> Text\n", @path)

      assert html =~ ~s(<h2 id="the-current-landscape">)
      assert html =~ ~s(<h3 id="executive-summary">)
    end

    test "renders tables and strikethrough" do
      html = Renderer.render!("| A | B |\n|---|---|\n| 1 | ~~2~~ |\n", @path)

      assert html =~ "<table>"
      assert html =~ "<del>2</del>"
    end

    test "keeps http(s) and mailto links" do
      html =
        Renderer.render!(
          "[a](https://example.com/a) [b](http://example.com/b) [c](mailto:someone@example.com) https://example.com/auto\n",
          @path
        )

      assert html =~ ~s(href="https://example.com/a")
      assert html =~ ~s(href="http://example.com/b")
      assert html =~ ~s(href="mailto:someone@example.com")
      assert html =~ ~s(href="https://example.com/auto")
    end

    test "rewrites a site-relative link to another Hugo post to that post on cheezyworld.ca" do
      html = Renderer.render!("[previous post](/post/adopting-ai-driven-development/)\n", @path)

      assert html =~ ~s(href="https://cheezyworld.ca/post/adopting-ai-driven-development/")
    end

    test "raises on a javascript: link" do
      raises(
        "[x](javascript:alert(1))\n",
        ~s{link "javascript:alert(1)" is not http(s) or mailto}
      )
    end

    test "raises on a data: link, a relative path and a protocol-relative link" do
      raises("[x](data:text/html,hi)\n", "is not http(s) or mailto")
      raises("[x](../secrets)\n", "is not http(s) or mailto")
      raises("[x](//evil.example.com/)\n", "is not http(s) or mailto")
      raises("[x](/post/../../etc)\n", "is not http(s) or mailto")
    end
  end

  describe "render!/3 images" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      tmp_dir |> Path.join("x.png") |> File.write!("png")
      %{opts: [image_root: tmp_dir]}
    end

    test "rewrites /img/x.png to /images/blog/x.png", %{opts: opts} do
      html = Renderer.render!("![A chart](/img/x.png)\n", @path, opts)

      assert html =~ ~s(<img loading="lazy" src="/images/blog/x.png" alt="A chart" />)
    end

    test "lazy-loads every image", %{opts: opts} do
      html = Renderer.render!("![One](/img/x.png)\n\n![Two](/img/x.png)\n", @path, opts)

      assert length(Regex.scan(~r/<img /, html)) == 2
      assert length(Regex.scan(~r/<img loading="lazy" /, html)) == 2
    end

    test "leaves a raw <img> in the body escaped, with no loading attribute", %{opts: opts} do
      html = Renderer.render!("<img src=\"x.png\">\n", @path, opts)

      assert html =~ "&lt;img"
      refute html =~ "<img "
      refute html =~ "loading="
    end

    test "reads alt text that wraps over a line break", %{opts: opts} do
      html = Renderer.render!("![Two\nlines](/img/x.png)\n", @path, opts)

      assert html =~ ~s(src="/images/blog/x.png")
      assert html =~ ~s(alt="Two)
    end

    test "raises on an external image", %{opts: opts} do
      raises("![A chart](https://example.com/x.png)\n", "is not a local /img/ image", opts)
    end

    test "raises on a data: image", %{opts: opts} do
      raises("![A chart](data:image/png;base64,AAAA)\n", "is not a local /img/ image", opts)
    end

    test "raises on an image path that tries to leave the image directory", %{opts: opts} do
      raises("![A chart](/img/../x.png)\n", "is not a local /img/ image", opts)
    end

    test "raises on a missing image file", %{opts: opts} do
      raises("![A chart](/img/missing.png)\n", "is missing from priv/static/images/blog/", opts)
    end

    test "raises on an image without alt text", %{opts: opts} do
      raises("![](/img/x.png)\n", "has no alt text", opts)
      raises("![   ](/img/x.png)\n", "has no alt text", opts)
    end

    test "checks images against priv/static/images/blog by default" do
      html = Renderer.render!("![Cost for one developer](/img/one-developer-cost.png)\n", @path)

      assert html =~ ~s(src="/images/blog/one-developer-cost.png")
    end
  end
end
