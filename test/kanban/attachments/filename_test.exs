defmodule Kanban.Attachments.FilenameTest do
  use ExUnit.Case, async: true

  alias Kanban.Attachments.Filename

  describe "sanitize/1" do
    test "keeps an ordinary name unchanged" do
      assert Filename.sanitize("Quarterly report.pdf") == {:ok, "Quarterly report.pdf"}
    end

    test "strips directory components from slash and backslash paths" do
      assert Filename.sanitize("../../etc/passwd") == {:ok, "passwd"}
      assert Filename.sanitize("/var/tmp/notes.md") == {:ok, "notes.md"}
      assert Filename.sanitize("C:\\Users\\x\\evil.png") == {:ok, "evil.png"}
      assert Filename.sanitize("mixed/dir\\name.txt") == {:ok, "name.txt"}
    end

    test "removes control and bidi override characters" do
      assert Filename.sanitize("photo\u202Egnp.exe") == {:ok, "photognp.exe"}
      assert Filename.sanitize("a\u2066b\u2069c.txt") == {:ok, "abc.txt"}
      assert Filename.sanitize("line\nbreak\t.txt") == {:ok, "linebreak.txt"}
      assert Filename.sanitize("nul\0byte.txt") == {:ok, "nulbyte.txt"}
      assert Filename.sanitize("zero\u200Bwidth.txt") == {:ok, "zerowidth.txt"}
    end

    test "trims surrounding whitespace" do
      assert Filename.sanitize("  spaced.txt  ") == {:ok, "spaced.txt"}
    end

    test "caps at 255 codepoints keeping the extension" do
      long = String.duplicate("a", 300) <> ".png"
      assert {:ok, capped} = Filename.sanitize(long)
      assert String.length(capped) == 255
      assert String.ends_with?(capped, ".png")
      assert capped == String.duplicate("a", 251) <> ".png"

      assert {:ok, exact} = Filename.sanitize(String.duplicate("b", 251) <> ".txt")
      assert String.length(exact) == 255
    end

    test "counts codepoints, not graphemes or bytes, when capping" do
      # "e" followed by a combining acute accent is one grapheme, two codepoints.
      long = String.duplicate("e\u0301", 200) <> ".md"
      assert {:ok, capped} = Filename.sanitize(long)
      assert length(String.codepoints(capped)) == 255
      assert String.ends_with?(capped, ".md")

      multibyte = String.duplicate("é", 300)
      assert {:ok, capped_multibyte} = Filename.sanitize(multibyte)
      assert length(String.codepoints(capped_multibyte)) == 255
    end

    test "caps a name whose extension is itself too long without keeping it" do
      long = "a." <> String.duplicate("x", 300)
      assert {:ok, capped} = Filename.sanitize(long)
      assert capped == "a." <> String.duplicate("x", 253)
    end

    test "caps a long name with no extension" do
      assert {:ok, capped} = "z" |> String.duplicate(400) |> Filename.sanitize()
      assert capped == String.duplicate("z", 255)
    end

    test "refuses a name that is empty, a single dot or two dots after sanitising" do
      assert Filename.sanitize("") == {:error, :empty}
      assert Filename.sanitize("   ") == {:error, :empty}
      assert Filename.sanitize(".") == {:error, :empty}
      assert Filename.sanitize("..") == {:error, :empty}
      assert Filename.sanitize("foo/..") == {:error, :empty}
      assert Filename.sanitize("foo\\.") == {:error, :empty}
      assert Filename.sanitize("dir/") == {:error, :empty}
    end

    test "refuses a name made only of control characters" do
      assert Filename.sanitize("\0\n\r\t\u202E") == {:error, :empty}
    end

    test "refuses invalid UTF-8 and non-string values" do
      assert Filename.sanitize(<<0xFF, 0xFE, "a.txt">>) == {:error, :invalid}
      assert Filename.sanitize(nil) == {:error, :invalid}
      assert Filename.sanitize(123) == {:error, :invalid}
    end

    test "max_codepoints/0 is 255" do
      assert Filename.max_codepoints() == 255
    end
  end
end
