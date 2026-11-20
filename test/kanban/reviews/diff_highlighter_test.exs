defmodule Kanban.Reviews.DiffHighlighterTest do
  use ExUnit.Case, async: true

  alias Kanban.ChangedFiles.Backfill
  alias Kanban.Reviews.DiffCache
  alias Kanban.Reviews.DiffHighlighter

  defp task_id, do: System.unique_integer([:positive])

  defp text(line), do: Enum.map_join(line.spans, & &1.text)

  defp classes(lines), do: lines |> Enum.flat_map(& &1.spans) |> Enum.map(& &1.class)

  defp shape(lines), do: Enum.map(lines, &{&1.kind, &1.old, &1.new})

  defp span?(line, class, text), do: %{class: class, text: text} in line.spans

  defp assert_valid_classes(lines) do
    for class <- classes(lines), do: assert(class in DiffHighlighter.classes())
  end

  @elixir_diff """
  diff --git a/lib/foo.ex b/lib/foo.ex
  index 1111111..2222222 100644
  --- a/lib/foo.ex
  +++ b/lib/foo.ex
  @@ -10,3 +10,3 @@ defmodule Foo do
   defmodule Foo do
  -  def bar, do: :old
  +  def bar, do: "new" # note
   end
  \\ No newline at end of file
  """

  describe "language/1" do
    test "names the language the extension's lexer highlights, else plain" do
      assert DiffHighlighter.language("lib/a.ex") == :elixir
      assert DiffHighlighter.language("test/a_test.EXS") == :elixir
      assert DiffHighlighter.language("lib/a.html.heex") == :heex
      assert DiffHighlighter.language("src/a.erl") == :erlang
      assert DiffHighlighter.language("include/a.hrl") == :erlang

      for path <- ["app.js", "app.css", "Makefile", "", nil] do
        assert DiffHighlighter.language(path) == :plain, "expected plain for #{inspect(path)}"
      end
    end
  end

  describe "lines/2" do
    test "highlights an Elixir hunk into the fixed classes with line numbers" do
      lines = DiffHighlighter.lines(@elixir_diff, "lib/foo.ex")

      assert shape(lines) == [
               {:hunk, nil, nil},
               {:ctx, 10, 10},
               {:del, 11, nil},
               {:add, nil, 11},
               {:ctx, 12, 12},
               {:ctx, nil, nil}
             ]

      [hunk, defmodule_line, del, add, end_line, no_newline] = lines

      assert hunk.spans == [%{class: :plain, text: "@@ -10,3 +10,3 @@ defmodule Foo do"}]
      assert span?(defmodule_line, :keyword, "defmodule")
      assert span?(defmodule_line, :module, "Foo")
      assert span?(del, :keyword, "def")
      assert span?(del, :function, "bar")
      assert span?(del, :atom, ":old")
      assert span?(add, :string, "\"new\"")
      assert span?(add, :comment, "# note")
      assert span?(end_line, :keyword, "end")
      assert no_newline.spans == [%{class: :plain, text: "\\ No newline at end of file"}]

      assert text(defmodule_line) == "defmodule Foo do"
      assert text(del) == "  def bar, do: :old"
      assert text(add) == "  def bar, do: \"new\" # note"
      assert_valid_classes(lines)
    end

    test "highlights HEEx" do
      diff = """
      @@ -1,1 +1,1 @@
      -<div class="a">{@old}</div>
      +<.button phx-click="save">{@label}</.button>
      """

      [_hunk, del, add] = DiffHighlighter.lines(diff, "lib/kanban_web/page.html.heex")

      assert span?(del, :keyword, "div")
      assert span?(add, :string, "\"save\"")
      assert span?(add, :function, ".button")
      assert span?(add, :atom, "@label")
      assert text(add) == "<.button phx-click=\"save\">{@label}</.button>"
      assert_valid_classes([del, add])
    end

    test "highlights Erlang" do
      diff = "@@ -1 +1 @@\n-foo(X) -> ok.\n+foo(X) -> ?MODULE. % note\n"

      [_hunk, del, add] = DiffHighlighter.lines(diff, "src/foo.erl")

      assert span?(del, :function, "foo")
      assert span?(del, :atom, "ok")
      assert span?(add, :comment, "% note")
      assert shape([del, add]) == [{:del, 1, nil}, {:add, nil, 1}]
    end

    test "an unknown extension gives plain spans only" do
      diff = "@@ -3,2 +3,2 @@\n const a = 1;\n-.x { color: red }\n+let b = \"s\";\n"

      for path <- ["app.js", "app.css", "Makefile", "README", nil] do
        lines = DiffHighlighter.lines(diff, path)

        assert shape(lines) == [{:hunk, nil, nil}, {:ctx, 3, 3}, {:del, 4, nil}, {:add, nil, 4}]
        assert lines |> classes() |> Enum.uniq() == [:plain]

        assert lines |> Enum.drop(1) |> Enum.map(&text/1) == [
                 "const a = 1;",
                 ".x { color: red }",
                 "let b = \"s\";"
               ]
      end
    end

    test "a hunk starting inside a string does not crash" do
      diff = """
      @@ -5,2 +5,3 @@
       still in heredoc\"\"\"
      +  x = "unterminated
      +  y = 'also
       end
      """

      lines = DiffHighlighter.lines(diff, "lib/foo.ex")

      assert length(lines) == 5

      assert lines |> Enum.drop(1) |> Enum.map(&text/1) ==
               ["still in heredoc\"\"\"", "  x = \"unterminated", "  y = 'also", "end"]

      assert_valid_classes(lines)
    end

    test "an empty or nil diff returns no lines" do
      assert DiffHighlighter.lines(nil, "a.ex") == []
      assert DiffHighlighter.lines("", "a.ex") == []
      assert DiffHighlighter.lines("diff --git a/x b/x\n--- a/x\n+++ b/x\n", "a.ex") == []
      assert DiffHighlighter.lines(Backfill.binary_placeholder(), "a.png") == []
      assert DiffHighlighter.lines("Binary files a/x.png and b/x.png differ", "x.png") == []
      assert DiffHighlighter.lines("\0\0", "a.ex") == []
      assert DiffHighlighter.highlight(task_id(), 0, nil, "a.ex") == []
      assert DiffHighlighter.highlight(task_id(), 0, "", "a.ex") == []
    end

    test "never returns more than the 500-line cap" do
      adds = Enum.map_join(1..600, "\n", &"+line #{&1}")

      diff =
        "@@ -0,0 +1,300 @@\n" <>
          adds <> "\n@@ -0,0 +301,300 @@\n" <> Backfill.truncation_marker() <> "\n"

      lines = DiffHighlighter.lines(diff, "a.txt")

      assert length(lines) == DiffHighlighter.max_lines()
      assert length(lines) == 500
      refute Enum.any?(lines, &(text(&1) == Backfill.truncation_marker()))
    end

    test "at most 100,000 bytes of one diff are lexed across all hunks" do
      code = String.duplicate("x = :a; ", 5_600)
      hunk = fn start -> "@@ -#{start},0 +#{start},1 @@\n+" <> code <> "\n" end
      lines = DiffHighlighter.lines(hunk.(1) <> hunk.(10) <> hunk.(20), "a.ex")

      [first, second, third] = Enum.filter(lines, &(&1.kind == :add))

      assert :atom in classes([first])
      assert :atom in classes([second])
      assert classes([third]) == [:plain]
      assert text(third) == code
    end

    test "the truncation marker is dropped" do
      diff = "@@ -1,3 +1,3 @@\n a\n-b\n" <> Backfill.truncation_marker()

      assert DiffHighlighter.lines(diff, "a.ex") |> Enum.map(&text/1) == [
               "@@ -1,3 +1,3 @@",
               "a",
               "b"
             ]
    end

    test "a very long single line falls back to plain and keeps its text" do
      long = String.duplicate("a = 1 ", 20_000)
      [_hunk, add] = DiffHighlighter.lines("@@ -0,0 +1 @@\n+" <> long, "a.ex")

      assert add.spans == [%{class: :plain, text: long}]
      assert {add.kind, add.old, add.new} == {:add, nil, 1}
    end

    test "a header without counts, an unparseable header and a '--' deletion" do
      assert "@@ -7 +7 @@\n-x\n+y\n" |> DiffHighlighter.lines("a.ex") |> shape() ==
               [{:hunk, nil, nil}, {:del, 7, nil}, {:add, nil, 7}]

      assert "@@ junk @@\n+x\n y\n" |> DiffHighlighter.lines("a.ex") |> shape() ==
               [{:hunk, nil, nil}, {:add, nil, nil}, {:ctx, nil, nil}]

      lines = DiffHighlighter.lines("@@ -1,2 +1,1 @@\n--- not a header\n a\n", "a.sql")

      assert shape(lines) == [{:hunk, nil, nil}, {:del, 1, nil}, {:ctx, 2, 1}]
      assert lines |> Enum.map(&text/1) |> Enum.at(1) == "-- not a header"
    end

    test "a diff with no hunk header is shown as one hunk without numbers" do
      assert "+<div>\n+  x\n-old\n same\n" |> DiffHighlighter.lines("a.heex") |> shape() ==
               [{:add, nil, nil}, {:add, nil, nil}, {:del, nil, nil}, {:ctx, nil, nil}]

      headed = "diff --git a/b.ex b/b.ex\nindex 1..2 100644\n--- a/b.ex\n+++ b/b.ex\n+x\n"
      assert headed |> DiffHighlighter.lines("b.ex") |> shape() == [{:add, nil, nil}]

      assert DiffHighlighter.lines("Binary files a/c.png and b/c.png differ\n", "c.png") == []
    end

    test "headers of a following file are dropped once a hunk's counts are spent" do
      diff = "@@ -1 +1 @@\n-a\n+b\ndiff --git a/y b/y\n--- a/y\n+++ b/y\n"

      assert diff |> DiffHighlighter.lines("a.ex") |> length() == 3
    end
  end

  describe "highlight/4" do
    test "caches by diff hash and misses after a resubmit" do
      id = task_id()
      first = "@@ -1 +1 @@\n-a\n+b\n"
      resubmitted = "@@ -1 +1 @@\n-a\n+c\n"

      assert id
             |> DiffCache.key(0, first, "a.ex")
             |> DiffCache.fetch_or_compute(fn -> :sentinel end) ==
               :sentinel

      assert DiffHighlighter.highlight(id, 0, first, "a.ex") == :sentinel

      assert DiffHighlighter.highlight(id, 0, resubmitted, "a.ex") ==
               DiffHighlighter.lines(resubmitted, "a.ex")

      assert DiffHighlighter.highlight(id, 1, first, "a.ex") ==
               DiffHighlighter.lines(first, "a.ex")

      assert DiffHighlighter.highlight(task_id(), 0, first, "a.ex") ==
               DiffHighlighter.lines(first, "a.ex")
    end

    test "parallel calls for one file compute once or return equal results" do
      id = task_id()
      diff = @elixir_diff

      results =
        1..50
        |> Task.async_stream(fn _ -> DiffHighlighter.highlight(id, 3, diff, "lib/foo.ex") end,
          max_concurrency: 50
        )
        |> Enum.map(fn {:ok, lines} -> lines end)

      assert [only] = Enum.uniq(results)
      assert only == DiffHighlighter.lines(diff, "lib/foo.ex")
      assert length(:ets.lookup(DiffCache, DiffCache.key(id, 3, diff, "lib/foo.ex"))) == 1
    end

    test "a file renamed with the same diff at the same index is highlighted for its new path" do
      id = task_id()
      diff = "@@ -1 +1 @@\n+def a, do: :ok\n"

      assert id
             |> DiffHighlighter.highlight(0, diff, "lib/a.ex")
             |> classes()
             |> Enum.member?(:keyword)

      assert id |> DiffHighlighter.highlight(0, diff, "notes/a.txt") |> classes() |> Enum.uniq() ==
               [:plain]
    end

    test "a diff over 1 MB is highlighted but not cached" do
      id = task_id()
      diff = "@@ -0,0 +1 @@\n+" <> String.duplicate("x", 1_100_000)

      assert DiffHighlighter.highlight(id, 0, diff, "a.ex") == DiffHighlighter.lines(diff, "a.ex")
      assert :ets.lookup(DiffCache, DiffCache.key(id, 0, diff, "a.ex")) == []
    end
  end
end
