defmodule KanbanWeb.MarketingImagesTest do
  @moduledoc """
  Guards the screenshots on the showcase pages, /product and /workflows: each
  image a page shows must exist under priv/static, be a PNG under
  images/marketing, and declare the size it really is. The page reserves the
  declared size before the image loads, so a wrong or missing size makes the
  page jump. Every PNG in images/marketing must also be used by one of the
  pages, so a replaced screenshot doesn't linger, and every /product
  subsection (`data-showcase-item`) must show an image or a code snippet.
  priv/static/images/marketing/README.md is the capture checklist.
  """
  use KanbanWeb.ConnCase, async: true

  @static_root Path.expand("../../../priv/static", __DIR__)
  @marketing_dir "/images/marketing/"
  @pages ["/product", "/workflows"]

  # Real PNGs for the size checks' own tests: 560x160 and 560x225.
  @fixture_png "/images/resources/guides/adding-task-step-1.png"
  @other_fixture_png "/images/resources/guides/adding-task-step-4.png"

  describe "the showcase pages' images" do
    test "every image the showcase pages reference exists under priv/static", %{conn: conn} do
      assert missing(page_images(conn)) == []
    end

    test "every showcase image is a PNG under /images/marketing/ with its real size", %{
      conn: conn
    } do
      images = page_images(conn)

      assert misplaced(images) == []
      assert size_mismatches(images) == []
    end

    test "no PNG in images/marketing is unreferenced", %{conn: conn} do
      assert unreferenced(page_images(conn), marketing_pngs()) == []
    end

    # Each /product subsection is a [data-showcase-item]; every one must show a
    # screenshot or, like the MCP subsection, a code snippet (W2458).
    test "every showcase subsection on /product shows an image or a code snippet", %{
      conn: conn
    } do
      html = conn |> get(~p"/product") |> html_response(200)

      assert bare_items(html, "/product") == []
      assert unmarked_subsections(html) == 0
    end
  end

  describe "the checks themselves" do
    test "report the page of a missing image" do
      images = [image("/product", "/images/marketing/nope.png", 1200, 800)]

      assert missing(images) == [
               "/product: /images/marketing/nope.png does not exist under priv/static"
             ]
    end

    test "flag an image outside images/marketing or not a PNG" do
      images = [
        image("/product", "/images/boards.png", 939, 462),
        image("/workflows", "/images/marketing/flow.svg", 800, 600),
        image("/workflows", "https://cdn.example.test/images/marketing/board.png", 800, 600),
        image("/workflows", "/images/marketing/board.png?vsn=d", 800, 600)
      ]

      assert misplaced(images) == [
               "/product: /images/boards.png is not a PNG under /images/marketing/",
               "/workflows: /images/marketing/flow.svg is not a PNG under /images/marketing/",
               "/workflows: https://cdn.example.test/images/marketing/board.png is not a PNG under /images/marketing/"
             ]
    end

    # The size checks read real PNGs, so they use guide screenshots whose sizes
    # guide_images_test.exs pins rather than showcase images, which are retaken
    # whenever the UI changes.
    test "report a declared size that doesn't match the PNG header" do
      images = [image("/product", @fixture_png, 517, 263)]

      assert size_mismatches(images) == [
               "/product: #{@fixture_png} declares 517x263 but is 560x160"
             ]
    end

    test "report an image that declares no width or height" do
      images = [
        image("/product", @fixture_png, nil, nil),
        image("/product", @other_fixture_png, 560, nil)
      ]

      assert size_mismatches(images) == [
               "/product: #{@fixture_png} declares no width and height",
               "/product: #{@other_fixture_png} declares no width and height"
             ]
    end

    test "accept a declared size that matches the PNG header" do
      assert @fixture_png |> static_path() |> File.regular?()
      assert size_mismatches([image("/product", @fixture_png, 560, 160)]) == []
    end

    test "a page with no images passes" do
      assert missing([]) == []
      assert misplaced([]) == []
      assert size_mismatches([]) == []
      assert unreferenced([], []) == []
    end

    test "report a showcase subsection with no image or code snippet" do
      html = """
      <main>
        <section id="plan">
          <div data-showcase-item><h3>Boards</h3><img src="/images/marketing/a.png"></div>
          <div data-showcase-item><h3>MCP</h3><pre><code>claude mcp add</code></pre></div>
          <div data-showcase-item><h3>Targets</h3><p>No picture yet</p></div>
          <div><h3>Unmarked</h3></div>
        </section>
      </main>
      """

      assert bare_items(html, "/product") == [
               ~s(/product: "Targets" shows no image or code snippet)
             ]

      assert unmarked_subsections(html) == 1
    end

    test "report a PNG in the folder that no page uses" do
      images = [image("/product", "/images/marketing/used.png", 1200, 800)]
      pngs = Enum.map(~w(used.png left-over.png), &static_path(@marketing_dir <> &1))

      assert unreferenced(images, pngs) == [
               "/images/marketing/left-over.png is in the folder but no page uses it"
             ]
    end

    test "read src, width and height from a page's main content only", %{conn: conn} do
      images = conn |> get(~p"/product") |> html_response(200) |> images_in("/product")

      # The layout's logos sit outside <main>, so only the showcase's own
      # screenshots are read.
      assert images != []

      assert Enum.all?(images, fn image ->
               image.page == "/product" and
                 String.starts_with?(image.src, "/images/marketing/product-") and
                 is_integer(image.width) and is_integer(image.height)
             end)

      assert images_in("<main><p>No pictures</p></main>", "/workflows") == []
    end
  end

  defp image(page, src, width, height),
    do: %{page: page, src: src, width: width, height: height}

  # One %{page, src, width, height} per <img> in each page's <main>, so the
  # layout's logos are left out.
  defp page_images(conn) do
    Enum.flat_map(@pages, fn page ->
      conn |> recycle() |> get(page) |> html_response(200) |> images_in(page)
    end)
  end

  defp images_in(html, page) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("main img")
    |> Enum.map(fn img ->
      image(page, attribute(img, "src"), dimension(img, "width"), dimension(img, "height"))
    end)
  end

  defp attribute(node, name) do
    case LazyHTML.attribute(node, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp dimension(node, name) do
    with value when is_binary(value) <- attribute(node, name),
         {number, ""} <- Integer.parse(value) do
      number
    else
      _ -> nil
    end
  end

  defp missing(images) do
    for %{page: page, src: src} <- images, not (src |> static_path() |> File.regular?()) do
      "#{page}: #{src} does not exist under priv/static"
    end
  end

  defp misplaced(images) do
    for %{page: page, src: src} <- images, not marketing_png?(src) do
      "#{page}: #{src} is not a PNG under #{@marketing_dir}"
    end
  end

  defp size_mismatches(images) do
    Enum.flat_map(images, fn image ->
      path = static_path(image.src)
      if File.regular?(path), do: size_mismatch(image, path), else: []
    end)
  end

  defp size_mismatch(%{page: page, src: src, width: width, height: height}, _path)
       when not is_integer(width) or not is_integer(height),
       do: ["#{page}: #{src} declares no width and height"]

  defp size_mismatch(%{page: page, src: src, width: width, height: height}, path) do
    case png_size!(path) do
      {^width, ^height} ->
        []

      {actual_width, actual_height} ->
        ["#{page}: #{src} declares #{width}x#{height} but is #{actual_width}x#{actual_height}"]
    end
  end

  # The heading of every [data-showcase-item] in <main> holding neither an
  # <img> nor a <pre>.
  defp bare_items(html, page) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("main [data-showcase-item]")
    |> Enum.filter(&(LazyHTML.query(&1, "img, pre") |> Enum.empty?()))
    |> Enum.map(fn item ->
      heading = item |> LazyHTML.query("h3") |> LazyHTML.text() |> String.trim()
      ~s(#{page}: "#{heading}" shows no image or code snippet)
    end)
  end

  # How many theme subsection headings sit outside a [data-showcase-item], so
  # a subsection added without the marker can't escape bare_items/2.
  defp unmarked_subsections(html) do
    main = html |> LazyHTML.from_document() |> LazyHTML.query("main")
    headings = main |> LazyHTML.query("section h3") |> Enum.count()
    marked = main |> LazyHTML.query("section [data-showcase-item] h3") |> Enum.count()
    headings - marked
  end

  defp unreferenced(images, pngs) do
    used = MapSet.new(images, &static_path(&1.src))

    for path <- pngs, path not in used do
      "#{@marketing_dir}#{Path.basename(path)} is in the folder but no page uses it"
    end
  end

  defp marketing_pngs,
    do: [@static_root, @marketing_dir, "*.png"] |> Path.join() |> Path.wildcard()

  # A site-relative path such as /images/marketing/board.png, never a URL on
  # another host. A digest query string (?vsn=d) is ignored.
  defp marketing_png?(src) do
    case local_path(src) do
      nil -> false
      path -> String.starts_with?(path, @marketing_dir) and String.ends_with?(path, ".png")
    end
  end

  defp local_path(src) when is_binary(src) do
    case URI.parse(src) do
      %URI{scheme: nil, host: nil, path: "/" <> _ = path} -> path
      _other -> nil
    end
  end

  defp local_path(_src), do: nil

  defp static_path(src), do: Path.join(@static_root, local_path(src) || "nowhere")

  # A PNG starts with an 8-byte signature and then the IHDR chunk, whose
  # first eight data bytes are the width and height as big-endian integers.
  defp png_size!(path) do
    case File.read!(path) do
      <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _length::32, "IHDR", width::32, height::32,
        _rest::binary>> ->
        {width, height}

      _other ->
        flunk("#{path} is not a PNG")
    end
  end
end
