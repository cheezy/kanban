defmodule Kanban.Workspaces.Export.Importer.RefsTest do
  use ExUnit.Case, async: true

  alias Kanban.Workspaces.Export.Importer.Refs

  doctest Refs, import: true

  test "shorten/1 cuts at 60 characters, counting multibyte characters as one" do
    sixty = String.duplicate("a", 60)

    assert Refs.shorten(sixty) == sixty
    assert Refs.shorten(sixty <> "a") == sixty <> "…"
    assert "日" |> String.duplicate(100) |> Refs.shorten() == String.duplicate("日", 60) <> "…"
  end

  test "shorten/1 never echoes a NUL byte or invalid UTF-8" do
    assert Refs.shorten("bad\0name") == "(text that cannot be shown)"
    assert Refs.shorten(<<0xFF, 0xFE>>) == "(text that cannot be shown)"
  end

  test "name_ref/1 keeps an integer id in full and shortens a text id" do
    name = String.duplicate("x", 200)
    id = 123_456_789_012

    assert Refs.name_ref(%{"id" => id, "name" => name}) ==
             ~s("#{String.duplicate("x", 60)}…", id 123456789012)

    assert Refs.name_ref(%{"id" => String.duplicate("7", 80)}) ==
             "id " <> String.duplicate("7", 60) <> "…"
  end

  test "name_ref/1 leaves out a name or id of another type" do
    assert Refs.name_ref(%{"id" => 4, "name" => %{"nested" => true}}) == "id 4"
    assert Refs.name_ref(%{"id" => [1], "name" => 5}) == "unnamed row"
    assert Refs.name_ref(%{}) == "unnamed row"
  end

  test "ref/1 handles every subject without raising" do
    assert Refs.ref(42) == "42"
    assert "W" |> String.duplicate(70) |> Refs.ref() == String.duplicate("W", 60) <> "…"
    assert Refs.ref(%{"id" => 1, "name" => "Todo"}) == ~s("Todo", id 1)
    assert Refs.ref(nil) == "unnamed row"
    assert Refs.ref([1, 2]) == "unnamed row"
    assert Refs.ref(1.5) == "unnamed row"
  end

  describe "printable/1" do
    test "shows ESC, newline, carriage return and tab as named escapes" do
      assert Refs.printable("a\e[31mred\e[0m") == ~S"a\e[31mred\e[0m"
      assert Refs.printable("one\ntwo\rthree\tfour") == ~S"one\ntwo\rthree\tfour"
    end

    test "shows every other C0 control and DEL as \\xNN" do
      for byte <- Enum.to_list(0..0x1F) -- [?\e, ?\n, ?\r, ?\t] do
        hex = byte |> Integer.to_string(16) |> String.pad_leading(2, "0")
        assert Refs.printable(<<?a, byte, ?b>>) == "a\\x#{hex}b"
      end

      assert Refs.printable("a\x7Fb") == ~S"a\x7Fb"
    end

    test "shows C1 controls and bidi controls as \\u{NNNN}" do
      assert Refs.printable("a\u009Bb") == ~S"a\u{009B}b"
      assert Refs.printable("a\u0085b") == ~S"a\u{0085}b"
      assert Refs.printable("evil\u202Etxt.exe") == ~S"evil\u{202E}txt.exe"
      assert Refs.printable("a\u2066b\u2069c") == ~S"a\u{2066}b\u{2069}c"
      assert Refs.printable("a\u200Fb\u061Cc") == ~S"a\u{200F}b\u{061C}c"
    end

    test "shows a byte that is not valid UTF-8 as \\xNN and keeps the rest" do
      assert Refs.printable(<<"ok", 0xFF, 0xC3, "!">>) == ~S"ok\xFF\xC3!"
    end

    test "keeps printable text, including non-ASCII, emoji joiners and backslashes" do
      for text <- [
            "",
            "Alpha board",
            "École ça marche 日本",
            "family 👨‍👩‍👧",
            "C:\\path\\name",
            "\u00A0nbsp"
          ] do
        assert Refs.printable(text) == text
      end
    end

    test "never leaves a control character in its output" do
      text = for byte <- 0..255, into: "", do: <<byte>>
      out = Refs.printable(text <> "\u0080\u009F\u202A\u2069")

      assert String.valid?(out)
      refute out =~ ~r/[\x00-\x1F\x7F\x{80}-\x{9F}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u
    end
  end
end
