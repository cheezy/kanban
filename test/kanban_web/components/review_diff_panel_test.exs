defmodule KanbanWeb.ReviewDiffPanelTest do
  @moduledoc """
  Tests for `KanbanWeb.ReviewDiffPanel.review_diff_panel/1`.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.ReviewDiffPanel

  defp render_panel(files, opts \\ []) do
    assigns = %{
      files: files,
      failing_tests_count: Keyword.get(opts, :failing_tests_count),
      selected_file: Keyword.get(opts, :selected_file)
    }

    rendered_to_string(~H"""
    <ReviewDiffPanel.review_diff_panel
      files={@files}
      failing_tests_count={@failing_tests_count}
      selected_file={@selected_file}
    />
    """)
  end

  describe "review_diff_panel/1 — base rendering" do
    test "has the data-review-diff-panel marker on the root" do
      assert render_panel(["lib/a.ex"]) =~ "data-review-diff-panel"
    end

    test "renders the header with the file count" do
      html = render_panel(["lib/a.ex", "lib/b.ex", "test/a_test.exs"])
      assert html =~ "data-review-diff-panel-title"
      assert html =~ "3 files"
    end

    test "renders each file path from the :files list" do
      files = ["lib/foo.ex", "lib/bar.ex", "test/baz_test.exs"]
      html = render_panel(files)

      for file <- files do
        assert html =~ file
      end

      # Count <li> rows by the bare `data-review-diff-panel-file`
      # attribute. Use a word boundary so the regex does not also match
      # the new `-file-path` and `-file-active` attributes.
      assert length(Regex.scan(~r/data-review-diff-panel-file\b(?!-)/, html)) == 3
    end

    test "uses monospace styling on file rows" do
      html = render_panel(["lib/a.ex"])
      assert html =~ "font-family: var(--font-mono)"
    end

    test "uses theme-aware surface-sunken background for the list (no hardcoded grey)" do
      html = render_panel(["lib/a.ex"])
      assert html =~ "background: var(--surface-sunken)"
      refute html =~ "bg-gray-900"
    end
  end

  describe "review_diff_panel/1 — failing tests pill" do
    test "renders 'N failing tests' pill when :failing_tests_count > 0" do
      html = render_panel(["lib/a.ex"], failing_tests_count: 3)
      assert html =~ "data-review-diff-panel-failing-tests"
      assert html =~ "3 failing tests"
    end

    test "uses singular 'failing test' when count is 1" do
      html = render_panel(["lib/a.ex"], failing_tests_count: 1)
      assert html =~ "1 failing test"
      refute html =~ "1 failing tests"
    end

    test "hides the failing tests pill when :failing_tests_count is 0" do
      html = render_panel(["lib/a.ex"], failing_tests_count: 0)
      refute html =~ "data-review-diff-panel-failing-tests"
      refute html =~ "failing test"
    end

    test "hides the failing tests pill when :failing_tests_count is nil" do
      html = render_panel(["lib/a.ex"])
      refute html =~ "data-review-diff-panel-failing-tests"
    end
  end

  describe "review_diff_panel/1 — diff rendering" do
    test "no diff section is rendered when no file is selected" do
      html = render_panel(["lib/a.ex"])
      refute html =~ "data-review-diff-panel-diff"
    end

    test "renders 'no diff available' when the selected file has no diff field" do
      html =
        render_panel(["lib/a.ex"], selected_file: %{"path" => "lib/a.ex"})

      assert html =~ ~s(data-review-diff-panel-diff-mode="empty")
      assert html =~ "No diff available for this file."
    end

    test "renders 'no diff available' for nil diff" do
      html =
        render_panel(["lib/a.ex"],
          selected_file: %{"path" => "lib/a.ex", "diff" => nil}
        )

      assert html =~ ~s(data-review-diff-panel-diff-mode="empty")
    end

    test "renders 'no diff available' for an empty-string diff" do
      html =
        render_panel(["lib/a.ex"],
          selected_file: %{"path" => "lib/a.ex", "diff" => ""}
        )

      assert html =~ ~s(data-review-diff-panel-diff-mode="empty")
    end

    test "renders binary placeholder for the binary marker" do
      html =
        render_panel(["assets/logo.png"],
          selected_file: %{
            "path" => "assets/logo.png",
            "diff" => "[binary file — no diff captured]"
          }
        )

      assert html =~ ~s(data-review-diff-panel-diff-mode="binary")
      assert html =~ "Binary file changed"
    end

    test "renders +/- and context lines with distinct classes" do
      diff = """
      --- a/lib/foo.ex
      +++ b/lib/foo.ex
      @@ -1,3 +1,4 @@
       defmodule Foo do
      +  @moduledoc "Foo"
      -  def old(x), do: x
         def call(x), do: x
       end
      """

      html =
        render_panel(["lib/foo.ex"],
          selected_file: %{"path" => "lib/foo.ex", "diff" => diff}
        )

      assert html =~ ~s(data-review-diff-panel-diff-mode="full")
      assert html =~ ~s(data-diff-line="add")
      assert html =~ ~s(data-diff-line="del")
      assert html =~ ~s(data-diff-line="hunk")
      assert html =~ ~s(data-diff-line="context")
      # +/- prefixes are preserved inside the rendered line text.
      assert html =~ "+  @moduledoc"
      assert html =~ "-  def old(x), do: x"
    end

    test "renders a diff with only context lines (no +/-)" do
      diff = """
      @@ -1,2 +1,2 @@
       defmodule Foo do
       end
      """

      html =
        render_panel(["lib/foo.ex"],
          selected_file: %{"path" => "lib/foo.ex", "diff" => diff}
        )

      assert html =~ ~s(data-review-diff-panel-diff-mode="full")
      assert html =~ ~s(data-diff-line="context")
      refute html =~ ~s(data-diff-line="add")
      refute html =~ ~s(data-diff-line="del")
    end

    test "renders a truncation notice when the marker is present" do
      diff = "+ a\n+ b\n[diff truncated at 500 lines]"

      html =
        render_panel(["lib/foo.ex"],
          selected_file: %{"path" => "lib/foo.ex", "diff" => diff}
        )

      assert html =~ ~s(data-review-diff-panel-diff-mode="truncated")
      assert html =~ "data-review-diff-panel-diff-truncated"
      assert html =~ "Diff truncated at 500 lines."
      # marker itself is not in the rendered line list.
      refute html =~ ~s(data-diff-line="context">[diff truncated)
    end

    test "shows 'view full diff in repo' link when diff_url is present" do
      diff = "+ a\n[diff truncated at 500 lines]"

      html =
        render_panel(["lib/foo.ex"],
          selected_file: %{
            "path" => "lib/foo.ex",
            "diff" => diff,
            "diff_url" => "https://github.com/x/y/pull/1/files#diff-abc"
          }
        )

      assert html =~ "data-review-diff-panel-diff-link"
      assert html =~ "View full diff in repo"
      assert html =~ "https://github.com/x/y/pull/1/files#diff-abc"
    end

    test "omits the link when diff_url is absent" do
      diff = "+ a\n[diff truncated at 500 lines]"

      html =
        render_panel(["lib/foo.ex"],
          selected_file: %{"path" => "lib/foo.ex", "diff" => diff}
        )

      assert html =~ "data-review-diff-panel-diff-truncated"
      refute html =~ "data-review-diff-panel-diff-link"
      refute html =~ "View full diff in repo"
    end

    test "renders a single very long line without crashing" do
      long_line = "+" <> String.duplicate("x", 5_000)

      html =
        render_panel(["lib/big.ex"],
          selected_file: %{"path" => "lib/big.ex", "diff" => long_line}
        )

      assert html =~ ~s(data-diff-line="add")
      assert html =~ String.duplicate("x", 100)
    end

    test "strips embedded NUL bytes defensively" do
      diff = "+ ok\0value"

      html =
        render_panel(["lib/foo.ex"],
          selected_file: %{"path" => "lib/foo.ex", "diff" => diff}
        )

      assert html =~ "+ okvalue"
      refute html =~ "\0"
    end

    test "html-escapes diff content (no raw HTML injection)" do
      diff = "+ <script>alert(1)</script>"

      html =
        render_panel(["lib/foo.ex"],
          selected_file: %{"path" => "lib/foo.ex", "diff" => diff}
        )

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    end
  end

  describe "review_diff_panel/1 — inline diff placement" do
    test "renders the diff inside the selected file's row, before later rows" do
      html =
        render_panel(["lib/a.ex", "lib/b.ex"],
          selected_file: %{"path" => "lib/a.ex", "diff" => "+ added line"}
        )

      assert html =~ "data-review-diff-panel-inline-diff"

      # The diff block must appear between the selected row and the next
      # file's row — inline in the list, not appended after it.
      {diff_pos, _} = :binary.match(html, "data-review-diff-panel-inline-diff")
      {next_row_pos, _} = :binary.match(html, "lib/b.ex")
      assert diff_pos < next_row_pos
    end

    test "renders no inline diff block when no file is selected" do
      html = render_panel(["lib/a.ex", "lib/b.ex"])
      refute html =~ "data-review-diff-panel-inline-diff"
    end
  end

  describe "review_diff_panel/1 — edge cases" do
    test "renders the empty state when :files is []" do
      html = render_panel([])
      assert html =~ "data-review-diff-panel-empty"
      assert html =~ "No files changed."
      refute html =~ "data-review-diff-panel-list"
    end

    test "renders the header with count 0 when :files is []" do
      assert render_panel([]) =~ "0 files"
    end

    test "renders a long file path without breaking layout (wrap class set)" do
      long_path =
        "lib/kanban_web/components/very/deeply/nested/folder/structure/with_a_really_long_filename.ex"

      html = render_panel([long_path])
      assert html =~ long_path
      assert html =~ "overflow-wrap: anywhere"
    end
  end
end
