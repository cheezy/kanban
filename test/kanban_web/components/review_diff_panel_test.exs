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
      failing_tests_count: Keyword.get(opts, :failing_tests_count)
    }

    rendered_to_string(~H"""
    <ReviewDiffPanel.review_diff_panel
      files={@files}
      failing_tests_count={@failing_tests_count}
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

      assert length(Regex.scan(~r/data-review-diff-panel-file/, html)) == 3
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
