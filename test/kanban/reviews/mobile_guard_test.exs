defmodule Kanban.Reviews.MobileGuardTest do
  use ExUnit.Case, async: true

  alias Kanban.ChangedFiles.Backfill
  alias Kanban.Reviews.MobileGuard
  alias Kanban.Tasks.Task

  defp added(n), do: Enum.map_join(1..n//1, "\n", &"+line #{&1}")

  defp entry(path, diff), do: %{"path" => path, "diff" => diff, "diff_url" => nil}

  defp task(entries, actual),
    do: %Task{changed_files: entries, actual_files_changed: actual}

  defp size_of(entries, actual \\ nil), do: entries |> task(actual) |> MobileGuard.size()

  defp large?(entries, actual \\ nil), do: entries |> task(actual) |> MobileGuard.large_change?()

  defp files(n), do: Enum.map(1..n, &entry("lib/file_#{&1}.ex", "+one"))

  describe "limits" do
    test "the constants are 10 files and 500 lines" do
      assert MobileGuard.max_files() == 10
      assert MobileGuard.max_changed_lines() == 500
      assert MobileGuard.limits() == %{max_files: 10, max_changed_lines: 500}

      assert Kanban.Devices.AppPolicy.phone_limits() == %{
               phone_max_files: MobileGuard.max_files(),
               phone_max_lines: MobileGuard.max_changed_lines()
             }
    end
  end

  describe "large_change?/1" do
    test "10 files and 500 lines are allowed; 11 files or 501 lines are large" do
      ten_files = files(10)
      refute large?(ten_files)
      assert large?(files(11))

      five_hundred = [entry("a.ex", added(250)), entry("b.ex", added(250))]
      assert size_of(five_hundred).changed_lines == 500
      refute large?(five_hundred)

      five_hundred_one = [entry("a.ex", added(250)), entry("b.ex", added(251))]
      assert large?(five_hundred_one)

      both_at_limit = Enum.map(1..10, &entry("lib/f#{&1}.ex", added(50)))

      assert size_of(both_at_limit) == %{
               files: 10,
               changed_lines: 500,
               truncated: false
             }

      refute large?(both_at_limit)
    end

    test "a diff cut at the per-diff cap is large" do
      capped = added(3) <> "\n" <> Backfill.truncation_marker() <> "\n"
      size = size_of([entry("a.ex", capped)])

      assert size == %{files: 1, changed_lines: 3, truncated: true}
      assert large?([entry("a.ex", capped)])
      refute large?([entry("a.ex", added(3))])
    end

    test "falls back to actual_files_changed when changed_files is empty" do
      size = size_of([], "a.ex, b.ex,,  a.ex , ")
      assert size == %{files: 2, changed_lines: 0, truncated: false}

      eleven = Enum.map_join(1..11, ",", &"f#{&1}.ex")
      assert large?([], eleven)
      refute large?([], "a.ex,b.ex")
    end

    test "a task with no files and no diffs is not large" do
      empty = %{files: 0, changed_lines: 0, truncated: false}

      assert size_of([]) == empty
      assert MobileGuard.size(%Task{changed_files: nil, actual_files_changed: nil}) == empty
      assert size_of([], "   ") == empty
      refute large?([])
    end

    test "accepts a size map" do
      refute MobileGuard.large_change?(%{files: 10, changed_lines: 500, truncated: false})
      assert MobileGuard.large_change?(%{files: 0, changed_lines: 0, truncated: true})
    end
  end

  describe "size/1 line counting" do
    test "counts added plus deleted lines and skips file headers, hunks and context" do
      diff = """
      diff --git a/a.ex b/a.ex
      --- a/a.ex
      +++ b/a.ex
      @@ -1,3 +1,3 @@
       context
      -old
      +new
      +another
      """

      assert size_of([entry("a.ex", diff)]).changed_lines == 3
    end

    test "a deleted line whose text began with \"-- \" is still counted" do
      diff = "@@ -1,2 +1,1 @@\n--- a comment\n kept\n"
      assert size_of([entry("a.ex", diff)]).changed_lines == 1
    end

    test ~s(inside a hunk a "--- " line followed by a "+++ " line is two changes, not a header) do
      diff = "--- a/a.ex\n+++ b/a.ex\n@@ -1,2 +1,2 @@\n--- old dashes\n+++ new pluses\n kept\n"
      assert size_of([entry("a.ex", diff)]).changed_lines == 2

      two_files =
        "@@ -1 +1 @@\n-a\n+b\n--- a/b.ex\n+++ b/b.ex\n@@ -3,0 +4 @@\n+c\n"

      assert size_of([entry("a.ex", two_files)]).changed_lines == 3

      # A header that leaves a count out (`@@ -1 +1 @@`) still opens a
      # one-line hunk, so the pair after it is a change, not a file header.
      one_line_hunk = "@@ -1 +1 @@\n--- old dashes\n+++ new pluses\n"
      assert size_of([entry("a.ex", one_line_hunk)]).changed_lines == 2
    end

    test "counts CRLF diffs and a concatenated multi-run patch" do
      diff = "--- a/a.ex\r\n+++ b/a.ex\r\n+x\r\n-y\r\n--- a/a.ex\r\n+++ b/a.ex\r\n+z\r\n"
      assert size_of([entry("a.ex", diff)]).changed_lines == 3
    end

    test "nil, binary-placeholder and non-string diffs count no lines" do
      entries = [
        entry("a.png", nil),
        entry("b.bin", "[binary file]"),
        %{"path" => "c.ex", "diff" => 12},
        %{"path" => "d.ex"}
      ]

      assert size_of(entries) == %{files: 4, changed_lines: 0, truncated: false}
    end

    test "counts lines only from the stored diffs, never from actual_files_changed" do
      size = size_of([entry("a.ex", "+x")], "a.ex,b.ex,c.ex")
      assert size == %{files: 1, changed_lines: 1, truncated: false}
    end

    test "atom-keyed entries are read too, and duplicate or blank paths count once or not at all" do
      entries = [
        %{path: "a.ex", diff: "+x\n-y"},
        %{"path" => "a.ex", "diff" => "+z"},
        %{"path" => "  ", "diff" => nil},
        %{"path" => nil, "diff" => nil},
        :not_a_map
      ]

      assert size_of(entries) == %{files: 1, changed_lines: 3, truncated: false}
    end

    test "only a marker on the last non-empty line marks a diff truncated" do
      marker = Backfill.truncation_marker()

      refute size_of([entry("a.ex", "#{marker}\n+x")]).truncated
      assert size_of([entry("a.ex", "+x\n#{marker}\n\n")]).truncated
    end
  end
end
