defmodule KanbanWeb.OgImageTest do
  @moduledoc """
  Tests for the default link-preview image: the PNG file itself and the
  og:image and twitter:image tags `KanbanWeb.SeoComponents.seo_head/1` renders
  for it.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.SeoComponents

  @static_root Path.expand("../../../priv/static", __DIR__)
  @image_path "/images/og/stride-og.png"
  @english_alt "The Stride logo beside the words: Kanban for humans and AI agents"

  defp render_head(attrs) do
    assigns = %{attrs: Map.new(attrs)}

    rendered_to_string(~H"""
    <SeoComponents.seo_head {@attrs} />
    """)
  end

  defp attr_of(html, selector, attribute) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(attribute)
  end

  defp tag_count(html, selector) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()
  end

  defp base, do: KanbanWeb.Endpoint.url()

  defp default_image_url, do: base() <> @image_path

  describe "priv/static/images/og/stride-og.png" do
    test "priv/static/images/og/stride-og.png exists and its header says 1200 by 630" do
      path = Path.join(@static_root, @image_path)

      assert File.regular?(path)
      assert png_size!(path) == {1200, 630}
    end

    test "is under 300 KB, so every platform accepts it" do
      %File.Stat{size: size} = @static_root |> Path.join(@image_path) |> File.stat!()

      assert size < 300 * 1024
    end

    test "carries no metadata chunks, so no local path or author detail ships with it" do
      chunks = @static_root |> Path.join(@image_path) |> File.read!() |> png_chunk_types()

      assert List.first(chunks) == "IHDR"
      assert List.last(chunks) == "IEND"
      assert Enum.reject(chunks, &(&1 in ["IHDR", "sRGB", "IDAT", "IEND"])) == []
    end
  end

  describe "phx.digest" do
    @describetag :tmp_dir

    test "the digested static path still resolves after mix phx.digest", %{tmp_dir: tmp_dir} do
      input = Path.join(tmp_dir, "input")
      output = Path.join(tmp_dir, "output")
      copy = Path.join(input, @image_path)
      copy |> Path.dirname() |> File.mkdir_p!()
      @static_root |> Path.join(@image_path) |> File.cp!(copy)

      assert :ok = Phoenix.Digester.compile(input, output, true)

      manifest = output |> Path.join("cache_manifest.json") |> File.read!() |> Jason.decode!()
      digested = manifest["latest"]["images/og/stride-og.png"]

      assert digested =~ ~r/^images\/og\/stride-og-[0-9a-f]{32}\.png$/
      assert png_size!(Path.join(output, digested)) == {1200, 630}
    end
  end

  describe "seo_head/1 — default image" do
    test "seo_head renders og:image and twitter:image as absolute URLs to the image" do
      html = render_head(path: "/")

      assert attr_of(html, ~s(meta[property="og:image"]), "content") == [default_image_url()]
      assert attr_of(html, ~s(meta[name="twitter:image"]), "content") == [default_image_url()]
      assert String.starts_with?(default_image_url(), ["http://", "https://"])
    end

    test "og:image:width, og:image:height and og:image:alt are rendered" do
      html = render_head(path: "/")

      assert attr_of(html, ~s(meta[property="og:image:width"]), "content") == ["1200"]
      assert attr_of(html, ~s(meta[property="og:image:height"]), "content") == ["630"]
      assert attr_of(html, ~s(meta[property="og:image:alt"]), "content") == [@english_alt]
      assert attr_of(html, ~s(meta[name="twitter:image:alt"]), "content") == [@english_alt]
    end

    test "a blank og_image gets the default" do
      for og_image <- [nil, "", "   "] do
        html = render_head(path: "/", og_image: og_image)

        assert attr_of(html, ~s(meta[property="og:image"]), "content") == [default_image_url()]
        assert attr_of(html, ~s(meta[property="og:image:width"]), "content") == ["1200"]
      end
    end

    test "the alt text is translated in every non-English locale" do
      for locale <- ~w(de es fr ja pt zh) do
        alt =
          Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
            render_head(path: "/") |> attr_of(~s(meta[property="og:image:alt"]), "content")
          end)

        assert [translated] = alt
        assert translated != @english_alt, "#{locale} is untranslated"
        assert translated =~ "Stride"
      end
    end

    test "default_og_image_alt/0 is the English text in the en locale" do
      assert Gettext.with_locale(KanbanWeb.Gettext, "en", &SeoComponents.default_og_image_alt/0) ==
               @english_alt
    end
  end

  describe "seo_head/1 — a page's own og_image" do
    test "a page that sets its own og_image overrides the default" do
      html = render_head(path: "/", og_image: "https://cdn.test/og.png")

      assert attr_of(html, ~s(meta[property="og:image"]), "content") == [
               "https://cdn.test/og.png"
             ]

      assert attr_of(html, ~s(meta[name="twitter:image"]), "content") == [
               "https://cdn.test/og.png"
             ]

      refute html =~ @image_path
    end

    test "an override carries no width, height or alt, which describe the default only" do
      html = render_head(path: "/", og_image: "https://cdn.test/og.png")

      assert tag_count(html, ~s(meta[property="og:image:width"])) == 0
      assert tag_count(html, ~s(meta[property="og:image:height"])) == 0
      assert tag_count(html, ~s(meta[property="og:image:alt"])) == 0
      assert tag_count(html, ~s(meta[name="twitter:image:alt"])) == 0
    end

    test "a path override is made absolute" do
      html = render_head(path: "/", og_image: "/images/marketing/product-hero.png")

      assert attr_of(html, ~s(meta[property="og:image"]), "content") == [
               base() <> "/images/marketing/product-hero.png"
             ]
    end

    test "an override that cannot be made absolute falls back to the default" do
      for og_image <- ["images/x.png", "//evil.test/x.png", "javascript:alert(1)", "https://"] do
        html = render_head(path: "/", og_image: og_image)

        assert attr_of(html, ~s(meta[property="og:image"]), "content") == [default_image_url()],
               "#{og_image} was not replaced by the default"
      end
    end
  end

  describe "og_image_url/1" do
    test "keeps an absolute http or https URL" do
      assert SeoComponents.og_image_url("https://cdn.test/a.png") == "https://cdn.test/a.png"
      assert SeoComponents.og_image_url("http://cdn.test/a.png") == "http://cdn.test/a.png"
    end

    test "resolves a root-relative path against the endpoint" do
      assert SeoComponents.og_image_url("/images/a.png") == base() <> "/images/a.png"
    end

    test "returns nil for anything it cannot make absolute" do
      for value <- [nil, 42, "a.png", "//cdn.test/a.png", "ftp://cdn.test/a.png", "https://"] do
        assert SeoComponents.og_image_url(value) == nil, "#{inspect(value)} was accepted"
      end
    end

    test "default_og_image_url/0 points at the committed image" do
      assert SeoComponents.default_og_image_url() == default_image_url()
    end
  end

  describe "rendered pages" do
    test "GET the og:image URL from the rendered home page answers 200 with image/png", %{
      conn: conn
    } do
      html = conn |> get(~p"/") |> html_response(200)

      assert [image_url] = attr_of(html, ~s(meta[property="og:image"]), "content")
      assert [^image_url] = attr_of(html, ~s(meta[name="twitter:image"]), "content")
      assert String.starts_with?(image_url, base())

      image_conn = build_conn() |> get(String.replace_prefix(image_url, base(), ""))

      assert image_conn.status == 200
      assert ["image/png" <> _] = get_resp_header(image_conn, "content-type")
    end

    test "a page's og_image assign reaches seo_head through the layout", %{conn: conn} do
      html =
        conn
        |> Plug.Conn.assign(:og_image, "https://cdn.test/page.png")
        |> get(~p"/")
        |> html_response(200)

      assert attr_of(html, ~s(meta[property="og:image"]), "content") == [
               "https://cdn.test/page.png"
             ]
    end
  end

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

  defp png_chunk_types(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, chunks::binary>>),
    do: chunk_types(chunks, [])

  defp png_chunk_types(_other), do: flunk("not a PNG")

  defp chunk_types(<<>>, acc), do: Enum.reverse(acc)

  defp chunk_types(<<length::32, type::binary-size(4), rest::binary>>, acc) do
    <<_data::binary-size(^length), _crc::32, rest::binary>> = rest
    chunk_types(rest, [type | acc])
  end
end
