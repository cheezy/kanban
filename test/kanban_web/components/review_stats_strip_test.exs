defmodule KanbanWeb.ReviewStatsStripTest do
  @moduledoc """
  Tests for `KanbanWeb.ReviewStatsStrip.review_stats_strip/1`.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.ReviewStatsStrip

  defp render_with(opts) do
    assigns = %{__assigns: Enum.into(opts, %{})}

    rendered_to_string(~H"""
    <ReviewStatsStrip.review_stats_strip
      acceptance={Map.get(@__assigns, :acceptance)}
      acceptance_passed={Map.get(@__assigns, :acceptance_passed)}
      tests={Map.get(@__assigns, :tests)}
      tests_passed={Map.get(@__assigns, :tests_passed)}
      diff={Map.get(@__assigns, :diff)}
      hooks={Map.get(@__assigns, :hooks)}
      hooks_passed={Map.get(@__assigns, :hooks_passed)}
    />
    """)
  end

  describe "review_stats_strip/1 — markers and structure" do
    test "has the data-review-stats-strip marker on the root" do
      html = render_with([])
      assert html =~ "data-review-stats-strip"
    end

    test "renders all four cells with their markers" do
      html = render_with([])
      assert html =~ ~s(data-review-stats-cell="acceptance")
      assert html =~ ~s(data-review-stats-cell="tests")
      assert html =~ ~s(data-review-stats-cell="diff")
      assert html =~ ~s(data-review-stats-cell="hooks")
    end

    test "renders all four labels via gettext" do
      html = render_with([])
      assert html =~ "Acceptance"
      assert html =~ "Testing strategy"
      assert html =~ "Patterns"
      assert html =~ "Pitfalls"
    end
  end

  describe "review_stats_strip/1 — values" do
    test "renders the supplied values" do
      html =
        render_with(
          acceptance: "5/5",
          tests: "12/12",
          diff: "3 files",
          hooks: "All pass"
        )

      assert html =~ ~r/<dd[^>]*>\s*5\/5\s*<\/dd>/
      assert html =~ ~r/<dd[^>]*>\s*12\/12\s*<\/dd>/
      assert html =~ ~r/<dd[^>]*>\s*3 files\s*<\/dd>/
      assert html =~ ~r/<dd[^>]*>\s*All pass\s*<\/dd>/
    end

    test "renders an em-dash when a value is nil" do
      html = render_with([])
      assert html =~ ~r/<dd[^>]*>\s*—\s*<\/dd>/
    end

    test "renders an em-dash when a value is empty string" do
      html = render_with(acceptance: "")
      assert html =~ ~r/<dd[^>]*>\s*—\s*<\/dd>/
    end

    test "value cells use tabular-nums for alignment" do
      html = render_with(acceptance: "5/5")
      assert html =~ "font-variant-numeric: tabular-nums"
    end
  end

  describe "review_stats_strip/1 — tones" do
    test "applies var(--st-done) when *_passed is true" do
      html = render_with(acceptance: "5/5", acceptance_passed: true)
      assert html =~ "var(--st-done)"
    end

    test "applies var(--st-blocked) when *_passed is false" do
      html = render_with(tests: "11/12", tests_passed: false)
      assert html =~ "var(--st-blocked)"
    end

    test "applies neutral var(--ink) for the Diff cell regardless of other tones" do
      html = render_with(diff: "3 files")
      # Diff cell always has the neutral ink tone
      assert html =~ "color: var(--ink);"
    end

    test "applies neutral var(--ink) when *_passed is nil" do
      html = render_with(tests: "—", tests_passed: nil)
      # All four cells should default to ink when no passed boolean is supplied
      assert html =~ "color: var(--ink);"
    end
  end

  describe "review_stats_strip/1 — visual styling" do
    test "uses var(--line) for cell borders" do
      html = render_with([])
      assert html =~ "border-right: 1px solid var(--line)"
    end

    test "renders inside a <dl> grid that collapses to two columns on mobile" do
      html = render_with([])

      # W1395: four equal columns crushed each cell to ~57px content at 375px,
      # bleeding the bold dd values into neighbours. The strip now shows two
      # columns on mobile and four at sm+, and each cell clips its own overflow.
      assert html =~ "grid grid-cols-2 sm:grid-cols-4"
      assert html =~ "min-width: 0; overflow: hidden;"
    end
  end
end
