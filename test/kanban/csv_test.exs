defmodule Kanban.CSVTest do
  use ExUnit.Case, async: true

  alias Kanban.CSV

  describe "neutralize_formula/1" do
    test "prefixes every formula trigger with a single quote" do
      for trigger <- ["=", "+", "-", "@", "\t", "\r"] do
        assert CSV.neutralize_formula(trigger <> "SUM(A1)") == "'" <> trigger <> "SUM(A1)"
      end
    end

    test "leaves ordinary and empty cells unchanged" do
      assert CSV.neutralize_formula("hello") == "hello"
      assert CSV.neutralize_formula("a=b") == "a=b"
      assert CSV.neutralize_formula("") == ""
    end
  end

  describe "encode_field/1" do
    test "renders nil as an empty cell and stringifies other terms" do
      assert CSV.encode_field(nil) == ""
      assert CSV.encode_field(42) == "42"
      assert CSV.encode_field(:work) == "work"
    end

    test "quotes cells containing commas, quotes, CR or LF and doubles quotes" do
      assert CSV.encode_field("a,b") == ~s("a,b")
      assert CSV.encode_field(~s(say "hi")) == ~s("say ""hi""")
      assert CSV.encode_field("line1\nline2") == ~s("line1\nline2")
      assert CSV.encode_field("a\rb") == ~s("a\rb")
    end

    test "neutralises before quoting, so a quoted formula stays inert" do
      assert CSV.encode_field(~s|=HYPERLINK("http://evil")|) ==
               ~s|"'=HYPERLINK(""http://evil"")"|
    end

    test "passes unicode through untouched" do
      assert CSV.encode_field("Grüße 日本") == "Grüße 日本"
    end
  end

  describe "encode_row/1 and encode/1" do
    test "joins cells with commas and rows with CRLF, without a trailing break" do
      assert CSV.encode_row(["a", nil, 1]) == "a,,1"
      assert CSV.encode([["h1", "h2"], ["x", "-1"]]) == "h1,h2\r\nx,'-1"
      assert CSV.encode([]) == ""
    end
  end
end
