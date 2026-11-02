defmodule Kanban.Attachments.ContentTypeTest do
  use ExUnit.Case, async: true

  alias Kanban.Attachments.ContentType

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR">>
  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF", 0>>
  @gif87 "GIF87a" <> <<1, 0, 1, 0>>
  @gif89 "GIF89a" <> <<1, 0, 1, 0>>
  @webp "RIFF" <> <<36, 0, 0, 0>> <> "WEBPVP8 "
  @pdf "%PDF-1.7\n%\xE2\xE3\xCF\xD3\n"
  # No NUL byte, so only the zip signature can refuse it as text.
  @zip <<"PK", 3, 4, 20>>

  describe "allowed/0 and allowed?/1" do
    test "lists exactly the nine allowed types" do
      assert Enum.sort(ContentType.allowed()) ==
               Enum.sort(~w(image/png image/jpeg image/gif image/webp application/pdf
                            text/plain text/markdown text/csv application/json))
    end

    test "refuses scriptable and archive types" do
      for type <- ~w(image/svg+xml text/html application/zip application/x-msdownload) do
        refute ContentType.allowed?(type)
      end

      refute ContentType.allowed?(nil)
    end
  end

  describe "extensions/0" do
    test "lists every allowed extension, lower case with its dot, sorted" do
      assert ContentType.extensions() ==
               ~w(.csv .gif .jpeg .jpg .json .log .markdown .md .pdf .png .txt .webp)
    end

    test "maps every extension it lists to an allowed type" do
      for extension <- ContentType.extensions() do
        assert ("file" <> extension) |> ContentType.from_extension() |> ContentType.allowed?()
      end
    end
  end

  describe "normalize/2" do
    test "normalises a declared type with a charset parameter and an alias" do
      assert ContentType.normalize("text/plain; charset=utf-8", "a.txt") == "text/plain"
      assert ContentType.normalize("image/jpg", "a.jpg") == "image/jpeg"
      assert ContentType.normalize("image/pjpeg", "a.jpg") == "image/jpeg"
      assert ContentType.normalize("text/x-markdown", "a.md") == "text/markdown"
      assert ContentType.normalize("text/x-csv", "a.csv") == "text/csv"
      assert ContentType.normalize("  IMAGE/PNG  ", "a.png") == "image/png"
    end

    test "maps the other names clients report for an allowed type" do
      for {declared, filename, type} <- [
            {"image/x-png", "shot.png", "image/png"},
            {"application/x-pdf", "r.pdf", "application/pdf"},
            {"text/comma-separated-values", "data.csv", "text/csv"},
            {"application/csv", "data.csv", "text/csv"},
            {"text/x-log", "server.log", "text/plain"},
            {"text/json", "x.json", "application/json"},
            {"text/x-json", "x.json", "application/json"},
            {"Application/CSV; header=present", "data.csv", "text/csv"}
          ] do
        assert ContentType.normalize(declared, filename) == type
        assert ContentType.allowed?(type)
        assert ContentType.extension_matches?(type, filename)
      end
    end

    test "reads application/vnd.ms-excel as text/csv only for a .csv name" do
      assert ContentType.normalize("application/vnd.ms-excel", "data.csv") == "text/csv"
      assert ContentType.normalize("application/vnd.ms-excel", "DATA.CSV") == "text/csv"

      for filename <- ["book.xls", "data.txt", "no-extension", nil, <<0xFF>>] do
        assert ContentType.normalize("application/vnd.ms-excel", filename) ==
                 "application/vnd.ms-excel"
      end

      refute ContentType.allowed?("application/vnd.ms-excel")
    end

    test "keeps a declared type that is not on the allow-list for the caller to refuse" do
      assert ContentType.normalize("image/svg+xml", "a.svg") == "image/svg+xml"
    end

    test "infers the type from the extension for an empty or octet-stream declared type" do
      assert ContentType.normalize("", "server.log") == "text/plain"
      assert ContentType.normalize(nil, "server.log") == "text/plain"
      assert ContentType.normalize("application/octet-stream", "notes.MD") == "text/markdown"

      assert ContentType.normalize("application/octet-stream; foo=bar", "a.json") ==
               "application/json"

      assert ContentType.normalize("", "archive.zip") == nil
      assert ContentType.normalize("", "no-extension") == nil
      assert ContentType.normalize("", nil) == nil
    end

    test "returns nil for a declared type that is not a valid string" do
      assert ContentType.normalize(<<0xFF, 0xFE>>, "a.txt") == nil
      assert ContentType.normalize(42, "a.txt") == nil
    end
  end

  describe "from_extension/1" do
    test "maps every allowed extension" do
      expected = %{
        "a.png" => "image/png",
        "a.jpg" => "image/jpeg",
        "a.jpeg" => "image/jpeg",
        "a.gif" => "image/gif",
        "a.webp" => "image/webp",
        "a.pdf" => "application/pdf",
        "a.txt" => "text/plain",
        "a.log" => "text/plain",
        "a.md" => "text/markdown",
        "a.markdown" => "text/markdown",
        "a.csv" => "text/csv",
        "a.json" => "application/json"
      }

      for {name, type} <- expected, do: assert(ContentType.from_extension(name) == type)
    end

    test "returns nil for unknown extensions and invalid values" do
      assert ContentType.from_extension("page.html") == nil
      assert ContentType.from_extension("image.svg") == nil
      assert ContentType.from_extension(<<0xFF, ".txt">>) == nil
      assert ContentType.from_extension(nil) == nil
    end
  end

  describe "matches?/2" do
    test "matches each allowed binary type to its signature" do
      assert ContentType.matches?("image/png", @png)
      assert ContentType.matches?("image/jpeg", @jpeg)
      assert ContentType.matches?("image/gif", @gif87)
      assert ContentType.matches?("image/gif", @gif89)
      assert ContentType.matches?("image/webp", @webp)
      assert ContentType.matches?("application/pdf", @pdf)
    end

    test "refuses a binary type whose bytes carry another signature or none" do
      refute ContentType.matches?("image/png", @pdf)
      refute ContentType.matches?("image/jpeg", @png)
      refute ContentType.matches?("image/gif", "GIF88a")
      refute ContentType.matches?("image/webp", "RIFF" <> <<0, 0, 0, 0>> <> "WAVE")
      refute ContentType.matches?("application/pdf", "plain text")
    end

    test "refuses a binary type whose head is shorter than its signature" do
      refute ContentType.matches?("image/png", <<0x89, "PN">>)
      refute ContentType.matches?("image/webp", "RIFF" <> <<0, 0, 0, 0>> <> "WEB")
      refute ContentType.matches?("image/jpeg", "")
    end

    test "refuses a text type whose head contains a NUL byte" do
      refute ContentType.matches?("text/plain", "hello\0world")
      refute ContentType.matches?("text/csv", <<"a,b", 0>>)
    end

    test "refuses UTF-16 text with a BOM because it contains NUL bytes" do
      utf16 = <<0xFF, 0xFE>> <> :unicode.characters_to_binary("hi", :utf8, {:utf16, :little})
      refute ContentType.matches?("text/plain", utf16)
    end

    test "refuses UTF-16 text with a BOM even when no character holds a NUL byte" do
      # Every code unit of these characters has two non-zero bytes, so only
      # the byte-order mark shows the file is UTF-16.
      for {bom, encoding} <- [{<<0xFF, 0xFE>>, :little}, {<<0xFE, 0xFF>>, :big}],
          text <- ["中文日本語", "Привет", "Γειά"],
          type <- ["text/plain", "text/csv", "application/json"] do
        body = bom <> :unicode.characters_to_binary(text, :utf8, {:utf16, encoding})

        refute String.contains?(body, <<0>>)
        refute ContentType.matches?(type, body)
      end
    end

    test "refuses a text type whose head carries a binary signature" do
      refute ContentType.matches?("text/plain", @pdf)
      refute ContentType.matches?("text/markdown", @png <> "x")
      refute ContentType.matches?("application/json", @jpeg <> "x")
      refute ContentType.matches?("text/plain", @gif89)
      refute ContentType.matches?("text/plain", @webp)
      refute ContentType.matches?("text/csv", @zip)
      refute ContentType.matches?("text/plain", <<"PK", 5, 6>>)
      refute ContentType.matches?("text/plain", <<"PK", 7, 8>>)
    end

    test "accepts Latin-1 csv bytes as text/csv" do
      latin1 = <<"name,city\nJos", 0xE9, ",Montr", 0xE9, "al\n">>
      refute String.valid?(latin1)
      assert ContentType.matches?("text/csv", latin1)
    end

    test "accepts a text file that starts with the letters MZ" do
      assert ContentType.matches?("text/plain", "MZ is how this note begins.")
    end

    test "accepts ordinary text, json and an empty head for text types" do
      assert ContentType.matches?("text/markdown", "# Title\n")
      assert ContentType.matches?("application/json", ~s({"a": 1}))
      assert ContentType.matches?("text/plain", "")
      assert ContentType.matches?("text/plain", "PK is fine without the zip bytes")
    end

    test "refuses every type outside the allow-list" do
      refute ContentType.matches?("image/svg+xml", "<svg/>")
      refute ContentType.matches?(nil, "text")
    end
  end

  describe "text?/1" do
    test "is true only for the four text types" do
      for type <- ~w(text/plain text/markdown text/csv application/json),
          do: assert(ContentType.text?(type))

      for type <- ~w(image/png application/pdf text/html), do: refute(ContentType.text?(type))
      refute ContentType.text?(nil)
    end
  end

  describe "text_body?/1" do
    test "refuses a NUL byte in any chunk, not only the first" do
      assert ContentType.text_body?(["plain ", "text"])
      assert ContentType.text_body?([])
      refute ContentType.text_body?(["plain ", "te\0xt"])
      refute ContentType.text_body?([String.duplicate("a", 600) <> <<"PK", 3, 4, 0>>])
    end
  end

  describe "extension_matches?/2" do
    test "accepts the type's own extensions, case-insensitively, and a name with none" do
      assert ContentType.extension_matches?("image/png", "a.png")
      assert ContentType.extension_matches?("image/jpeg", "a.JPEG")
      assert ContentType.extension_matches?("text/markdown", "a.markdown")
      assert ContentType.extension_matches?("text/plain", "Makefile")
      assert ContentType.extension_matches?("image/png", "no-extension")
    end

    test "lets text/plain take any text extension, but no other type" do
      for name <- ~w(a.md a.csv a.json a.log a.txt),
          do: assert(ContentType.extension_matches?("text/plain", name))

      refute ContentType.extension_matches?("text/csv", "a.txt")
      refute ContentType.extension_matches?("application/json", "a.md")
      refute ContentType.extension_matches?("text/plain", "a.png")
    end

    test "refuses an unknown or excluded extension and an invalid name" do
      for name <- ~w(a.html a.svg a.zip a.exe a.tar.gz .html .SVG .zip ../.svg .bashrc) do
        refute ContentType.extension_matches?("text/plain", name)
      end

      refute ContentType.extension_matches?("image/png", "a.pdf")
      refute ContentType.extension_matches?("text/plain", <<0xFF, ".txt">>)
      refute ContentType.extension_matches?("text/plain", nil)
    end
  end
end
