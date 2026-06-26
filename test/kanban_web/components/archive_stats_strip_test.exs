defmodule KanbanWeb.ArchiveStatsStripTest do
  @moduledoc """
  Tests for `KanbanWeb.ArchiveStatsStrip.archive_stats_strip/1`.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.ArchiveStatsStrip

  defp render_strip(stats) do
    assigns = %{stats: stats}

    rendered_to_string(~H"""
    <ArchiveStatsStrip.archive_stats_strip stats={@stats} />
    """)
  end

  defp full_stats(overrides) do
    Map.merge(%{total: 7, completed: 4}, overrides)
  end

  describe "archive_stats_strip/1 — markers and structure" do
    test "renders the data-archive-stats-strip marker on the root" do
      assert render_strip(full_stats(%{})) =~ "data-archive-stats-strip"
    end

    test "renders the two per-cell markers" do
      html = render_strip(full_stats(%{}))

      for marker <- ~w(total completed) do
        assert html =~ ~s(data-archive-stats-cell="#{marker}")
      end
    end

    test "does not render the removed cells" do
      html = render_strip(full_stats(%{}))

      for marker <- ~w(cancelled wontdo-duplicate avg-cycle) do
        refute html =~ ~s(data-archive-stats-cell="#{marker}")
      end
    end

    test "uses a content-sized 2-column grid that does not stretch full width" do
      html = render_strip(full_stats(%{}))
      assert html =~ "grid-template-columns: repeat(2, max-content)"
      assert html =~ "width: fit-content"
    end
  end

  describe "archive_stats_strip/1 — values" do
    test "renders the integer values for each counter cell" do
      html = render_strip(full_stats(%{total: 12, completed: 7}))

      # The 24px tabular-numerics dd contains each value.
      assert html =~ ~r/>\s*12\s*</
      assert html =~ ~r/>\s*7\s*</
    end

    test "renders 0 when a counter bucket is empty" do
      html = render_strip(full_stats(%{total: 0, completed: 0}))
      assert length(Regex.scan(~r/>\s*0\s*</, html)) >= 2
    end
  end

  describe "archive_stats_strip/1 — tone tokens" do
    test "Completed cell uses the st-done ink token" do
      html = render_strip(full_stats(%{}))
      assert html =~ ~r/data-archive-stats-cell="completed"[\s\S]*?color: var\(--st-done\)/
    end

    test "the Total cell value uses the default --ink token" do
      html = render_strip(full_stats(%{}))
      # The value dd is the second `color: var(...)` in each cell (the
      # first is the dt label which is always var(--ink-3)). Match the
      # 24px font-size that uniquely identifies the value dd.
      assert html =~
               ~r/data-archive-stats-cell="total"[\s\S]*?font-size: 24px[\s\S]*?color: var\(--ink\)/
    end

    test "no hardcoded Tailwind greys leak into the markup" do
      html = render_strip(full_stats(%{}))
      refute html =~ "text-gray-"
      refute html =~ "bg-gray-"
      refute html =~ "bg-white"
    end
  end

  describe "archive_stats_strip/1 — labels" do
    test "renders the two English labels" do
      html = render_strip(full_stats(%{}))
      assert html =~ "Total archived"
      assert html =~ "Completed"
    end

    test "does not render the removed labels" do
      html = render_strip(full_stats(%{}))
      refute html =~ "Cancelled"
      refute html =~ "Won&#39;t do · duplicate"
      refute html =~ "Avg cycle · completed"
    end
  end
end
