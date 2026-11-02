defmodule KanbanWeb.AttachmentResponseTest do
  use ExUnit.Case, async: true

  alias Kanban.Attachments.ContentType
  alias Kanban.Attachments.TaskAttachment
  alias KanbanWeb.AttachmentResponse

  doctest KanbanWeb.AttachmentResponse

  @rlo <<0x202E::utf8>>
  @zwj <<0x200D::utf8>>
  @zwnj <<0x200C::utf8>>

  # Printable ASCII only: no CR, LF or other control character.
  @printable_ascii ~r/\A[\x20-\x7E]+\z/

  describe "safe_filename/1" do
    test "replaces quotes and slashes and drops control characters in the ASCII filename" do
      # Control characters are removed, as in filename*, not replaced.
      assert AttachmentResponse.safe_filename(~s(a"b\r\n;c.pdf)) == "a_b_c.pdf"
      assert AttachmentResponse.safe_filename("../../etc/passwd") == "_.._etc_passwd"
      assert AttachmentResponse.safe_filename("a\\b\tc.txt") == "a_bc.txt"
      assert AttachmentResponse.safe_filename("résumé.pdf") == "r_sum_.pdf"
      # Format characters are removed before the ASCII pass, as in filename*,
      # so the two names agree.
      assert AttachmentResponse.safe_filename("evil#{@rlo}fdp.exe") == "evilfdp.exe"

      assert AttachmentResponse.safe_filename("Q3 report-final_v2.pdf") ==
               "Q3 report-final_v2.pdf"

      for hostile <- [~s(a"b\r\n;c.pdf), "../../etc/passwd", "evil#{@rlo}fdp.exe", "\r\n\"\"\""] do
        header = AttachmentResponse.content_disposition(:attachment, hostile)
        assert header =~ @printable_ascii
        assert header |> String.graphemes() |> Enum.count(&(&1 == ~s("))) == 2
      end
    end
  end

  describe "filename_star/1" do
    test "strips control and bidi format characters from the filename* value" do
      assert AttachmentResponse.filename_star("evil#{@rlo}fdp.exe") == "evilfdp.exe"
      assert AttachmentResponse.filename_star("résumé.pdf") == "r%C3%A9sum%C3%A9.pdf"
      assert AttachmentResponse.filename_star("a/b\\c\r\n.txt") == "a_b_c.txt"
      assert AttachmentResponse.filename_star("a#{@zwj}b.txt") == "a%E2%80%8Db.txt"
      assert AttachmentResponse.filename_star(~s(x"y;z.txt)) == "x%22y%3Bz.txt"

      assert AttachmentResponse.content_disposition(:attachment, "résumé.pdf") ==
               "attachment; filename=\"r_sum_.pdf\"; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf"

      assert AttachmentResponse.content_disposition(:inline, "photo.png") ==
               "inline; filename=\"photo.png\"; filename*=UTF-8''photo.png"
    end
  end

  describe "joiners" do
    # Kanban.Attachments.Filename keeps U+200C and U+200D because emoji
    # sequences and scripts such as Persian need them; the served name must
    # keep them too, or the saved file is named differently from the stored
    # one.
    test "filename* keeps the zero-width joiner and non-joiner the stored name has" do
      family = "family" <> "👨" <> @zwj <> "👩" <> @zwj <> "👧" <> ".png"
      persian = "نامه" <> @zwnj <> "ها.txt"

      for name <- [family, persian] do
        assert name |> AttachmentResponse.filename_star() |> URI.decode() == name
      end
    end

    test "the ASCII fallback drops a joiner, like every format character" do
      assert AttachmentResponse.safe_filename("a#{@zwj}b.txt") == "ab.txt"
    end
  end

  describe "extension-only names" do
    test "a name that is only an extension keeps it after a base name" do
      for {name, expected} <- [
            {".txt", "attachment.txt"},
            {"...png", "attachment.png"},
            {". .pdf", "attachment.pdf"},
            {".hidden", "attachment.hidden"}
          ] do
        assert AttachmentResponse.safe_filename(name) == expected
        assert AttachmentResponse.filename_star(name) == expected
      end
    end

    test "a hidden name with its own extension only loses the leading dot" do
      assert AttachmentResponse.safe_filename(".notes.txt") == "notes.txt"
      assert AttachmentResponse.filename_star(".notes.txt") == "notes.txt"
    end

    test "a format character before the dot gives both names the same base" do
      assert AttachmentResponse.safe_filename("#{@rlo}.txt") == "attachment.txt"
      assert AttachmentResponse.filename_star("#{@rlo}.txt") == "attachment.txt"
    end
  end

  describe "fallback" do
    test "falls back to attachment when the sanitised name is empty" do
      for name <- ["", "....", "  ", " . . ", <<0xFF>>, nil, 42] do
        assert AttachmentResponse.safe_filename(name) == "attachment"
        assert AttachmentResponse.filename_star(name) == "attachment"
      end

      assert AttachmentResponse.filename_star("#{@rlo}\r\n") == "attachment"
    end
  end

  describe "truncation" do
    test "truncates a long name and keeps its extension" do
      long = String.duplicate("a", 300) <> ".pdf"
      ascii = AttachmentResponse.safe_filename(long)
      assert String.length(ascii) == 150
      assert String.ends_with?(ascii, ".pdf")

      no_extension = "b" |> String.duplicate(300) |> AttachmentResponse.safe_filename()
      assert no_extension == String.duplicate("b", 150)

      # A dot followed by a long run is part of the name, not an extension.
      long_tail = AttachmentResponse.safe_filename("x." <> String.duplicate("c", 300))
      assert String.length(long_tail) == 150

      unicode = String.duplicate("é", 200) <> ".txt"
      assert byte_size(unicode) > 255

      unicode_ascii = AttachmentResponse.safe_filename(unicode)
      assert byte_size(unicode_ascii) == 150
      assert String.ends_with?(unicode_ascii, ".txt")

      star = AttachmentResponse.filename_star(String.duplicate("é", 400) <> ".txt")
      assert String.ends_with?(star, ".txt")
      assert star |> URI.decode() |> String.length() == 255
    end

    test "counts code points, so one huge grapheme cannot grow the header" do
      # One grapheme of 5,001 code points: a base and 5,000 combining marks.
      grapheme = "e" <> String.duplicate(<<0x0301::utf8>>, 5_000)
      assert String.length(grapheme) == 1

      star = AttachmentResponse.filename_star(grapheme <> ".txt")
      assert star |> URI.decode() |> String.codepoints() |> length() == 255
      assert String.ends_with?(star, ".txt")
    end
  end

  describe "inline_image?/1" do
    test "inline_image? is true only for png, jpeg, gif and webp" do
      for type <- ~w(image/png image/jpeg image/gif image/webp) do
        assert AttachmentResponse.inline_image?(type)
      end

      for type <- [
            "image/svg+xml",
            "text/html",
            "application/pdf",
            "image/bmp",
            "IMAGE/PNG",
            "image/png; charset=binary",
            nil
          ] do
        refute AttachmentResponse.inline_image?(type)
      end
    end
  end

  describe "served_content_type/1 and headers" do
    test "serves a type outside the allow-list as application/octet-stream" do
      for type <- ContentType.allowed() do
        assert AttachmentResponse.served_content_type(type) == type
      end

      for type <- ["image/svg+xml", "text/html", "application/x-msdownload", nil] do
        assert AttachmentResponse.served_content_type(type) == "application/octet-stream"
      end

      assert AttachmentResponse.security_headers() == [
               {"x-content-type-options", "nosniff"},
               {"content-security-policy", "default-src 'none'; frame-ancestors 'none'; sandbox"},
               {"cache-control", "private, no-store"},
               {"cross-origin-resource-policy", "same-origin"}
             ]

      attachment = %TaskAttachment{filename: "page.html", content_type: "text/html"}

      assert AttachmentResponse.response_headers(attachment, :attachment) == [
               {"content-type", "application/octet-stream"},
               {"content-disposition",
                "attachment; filename=\"page.html\"; filename*=UTF-8''page.html"}
               | AttachmentResponse.security_headers()
             ]
    end
  end
end
