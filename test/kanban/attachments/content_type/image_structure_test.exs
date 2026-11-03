defmodule Kanban.Attachments.ContentType.ImageStructureTest do
  use ExUnit.Case, async: true

  alias Kanban.Attachments.ContentType
  alias Kanban.Attachments.ContentType.ImageStructure

  @png_signature <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>
  @html "<html><script>alert(1)</script></html>"

  defp chunk(type, data),
    do: <<byte_size(data)::32>> <> type <> data <> <<:erlang.crc32(type <> data)::32>>

  defp ihdr(width \\ 1, height \\ 1), do: chunk("IHDR", <<width::32, height::32, 8, 0, 0, 0, 0>>)

  defp png(chunks), do: @png_signature <> Enum.join(chunks)

  defp tiny_png,
    do: png([ihdr(), chunk("IDAT", <<120, 1, 0, 0, 0, 255, 255>>), chunk("IEND", "")])

  # SOI, an APP0 JFIF segment, a DQT segment, then the start of scan.
  defp jpeg do
    <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF", 0, 1, 1, 0, 0, 1, 0, 1, 0, 0>> <>
      <<0xFF, 0xDB, 0, 4, 0, 1>> <> <<0xFF, 0xDA, 0, 8, 1, 1, 0, 0, 63, 0, 0x12, 0x34>>
  end

  # A 1x1 GIF89a with a two-colour global table, then an image descriptor.
  defp gif(packed \\ 0x80, table \\ <<0, 0, 0, 255, 255, 255>>) do
    "GIF89a" <> <<1, 0, 1, 0, packed, 0, 0>> <> table <> <<0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0>>
  end

  defp webp(fourcc, payload), do: "RIFF" <> <<100::little-32>> <> "WEBP" <> fourcc <> payload

  describe "real images" do
    test "every PNG shipped in priv/static passes" do
      paths = Path.wildcard("priv/static/**/*.png")
      assert paths != []

      for path <- paths do
        {:ok, head} = File.open(path, [:read, :binary, :raw], &IO.binread(&1, 512))
        assert ContentType.matches?("image/png", head), "expected #{path} to pass"
      end
    end
  end

  describe "png?/1" do
    test "accepts a well-formed PNG, one cut anywhere by the head, and a bare IHDR header" do
      full = tiny_png()
      assert ImageStructure.png?(full)

      for size <- 8..byte_size(full) do
        assert binary_part(full, 0, size) |> ImageStructure.png?(), "cut at #{size}"
      end

      assert ImageStructure.png?(@png_signature <> <<0, 0, 0, 13, "IHDR">>)
    end

    test "refuses a PNG signature followed by anything but a well-formed IHDR" do
      refute ImageStructure.png?(@png_signature <> @html)
      refute ImageStructure.png?(@png_signature <> <<0, 0, 0, 13, "IHDR">> <> @html)
      refute png([chunk("IDAT", "x"), ihdr()]) |> ImageStructure.png?()
      refute png([ihdr(0, 1)]) |> ImageStructure.png?()
      refute png([ihdr(1, 0)]) |> ImageStructure.png?()
    end

    test "refuses a bad CRC, a chunk type that is not four letters, or bytes after IEND" do
      <<head::binary-size(29), _crc::32, rest::binary>> = tiny_png()
      refute ImageStructure.png?(head <> <<0::32>> <> rest)

      refute (png([ihdr()]) <> @html) |> ImageStructure.png?()
      refute png([ihdr(), <<1::32, "ID4T", "x", 0::32>>]) |> ImageStructure.png?()
      refute (tiny_png() <> "x") |> ImageStructure.png?()
      refute png([ihdr(), <<0x80000000::32, "IDAT">>]) |> ImageStructure.png?()
    end
  end

  describe "jpeg?/1" do
    test "accepts a segment chain up to the start of scan, cut anywhere by the head" do
      full = jpeg()
      assert ImageStructure.jpeg?(full)

      for size <- 2..byte_size(full) do
        assert binary_part(full, 0, size) |> ImageStructure.jpeg?(), "cut at #{size}"
      end

      assert ImageStructure.jpeg?(<<0xFF, 0xD8, 0xFF, 0xFF, 0xE1, 0, 2, 0xFF, 0xD9>>)
    end

    test "refuses a start of image followed by anything but marker segments" do
      refute ImageStructure.jpeg?(<<0xFF, 0xD8, 0xFF>> <> @html)
      refute (binary_part(jpeg(), 0, 20) <> @html) |> ImageStructure.jpeg?()
      refute ImageStructure.jpeg?(<<0xFF, 0xD8, 0xFF, 0xDA, 0, 2>>)
      refute ImageStructure.jpeg?(<<0xFF, 0xD8, 0xFF, 0xE0, 0, 1, 0xFF, 0xDA>>)
      refute ImageStructure.jpeg?(<<0xFF, 0xD8, 0xFF, 0xE0, 0, 2, 0xFF, 0xD8, 0, 2>>)
      refute ImageStructure.jpeg?(<<0xFF, 0xD8, 0xFF, 0xE0, 0, 2, 0xFF, 0xD9, "x">>)
    end
  end

  describe "gif?/1" do
    test "accepts a block introducer after the screen descriptor and its colour table" do
      assert gif() |> ImageStructure.gif?()
      assert gif(0x00, "") |> ImageStructure.gif?()
      assert ImageStructure.gif?("GIF87a" <> <<1, 0, 1, 0, 0, 0, 0, 0x3B>>)
      assert ImageStructure.gif?("GIF89a" <> <<1, 0, 1, 0, 0, 0, 0, 0x21, 0xF9>>)
      # A 256-colour table runs past a 512-byte head, so the introducer cannot be seen.
      assert binary_part(gif(0x87, :binary.copy(<<1>>, 768)), 0, 512) |> ImageStructure.gif?()
      assert ImageStructure.gif?("GIF89a" <> <<1, 0>>)
    end

    test "refuses a signature followed by anything but a block" do
      refute ImageStructure.gif?("GIF89a" <> @html)
      refute gif(0x00, <<0, 0, 0, 255, 255, 255>>) |> ImageStructure.gif?()

      refute ImageStructure.gif?(
               "GIF89a" <> <<1, 0, 1, 0, 0x81, 0, 0>> <> :binary.copy(<<0>>, 12) <> "<"
             )
    end
  end

  describe "webp?/1" do
    test "accepts VP8, VP8L and VP8X chunks, and a head cut inside the frame header" do
      assert webp("VP8 ", <<20::little-32, 0x50, 0x01, 0x00, 0x9D, 0x01, 0x2A>>)
             |> ImageStructure.webp?()

      assert webp("VP8L", <<20::little-32, 0x2F, 0, 0>>) |> ImageStructure.webp?()
      assert webp("VP8X", <<10::little-32, 0::80>>) |> ImageStructure.webp?()
      assert webp("VP8 ", <<20::little-32, 0x50, 0x01>>) |> ImageStructure.webp?()
    end

    test "refuses another first chunk or a frame without its marker" do
      refute ImageStructure.webp?("RIFF" <> <<100::little-32>> <> "WEBP" <> @html)
      refute webp("VP8 ", @html) |> ImageStructure.webp?()
      refute webp("VP8L", <<20::little-32, "<html>">>) |> ImageStructure.webp?()
      refute webp("ALPH", <<0::32>>) |> ImageStructure.webp?()
      refute ImageStructure.webp?("RIFF" <> <<100::little-32>> <> "WEBP")
    end
  end

  test "ContentType.matches?/2 refuses the polyglots and keeps refusing other signatures" do
    refute ContentType.matches?("image/png", @png_signature <> @html)
    refute ContentType.matches?("image/jpeg", <<0xFF, 0xD8, 0xFF>> <> @html)
    refute ContentType.matches?("image/gif", "GIF89a" <> @html)
    refute ContentType.matches?("image/webp", webp("VP8 ", @html))
    refute ContentType.matches?("image/png", jpeg())

    assert ContentType.matches?("image/png", tiny_png())
    assert ContentType.matches?("image/jpeg", jpeg())
    assert ContentType.matches?("image/gif", gif())
  end
end
