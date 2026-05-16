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
    base = %{
      total: 7,
      completed: 4,
      cancelled: 1,
      wontdo_duplicate: 2,
      deferred: 0,
      avg_cycle_minutes: 161
    }

    Map.merge(base, overrides)
  end

  describe "archive_stats_strip/1 — markers and structure" do
    test "renders the data-archive-stats-strip marker on the root" do
      assert render_strip(full_stats(%{})) =~ "data-archive-stats-strip"
    end

    test "renders all five per-cell markers" do
      html = render_strip(full_stats(%{}))

      for marker <- ~w(total completed cancelled wontdo-duplicate avg-cycle) do
        assert html =~ ~s(data-archive-stats-cell="#{marker}")
      end
    end

    test "uses a 5-column CSS grid" do
      html = render_strip(full_stats(%{}))
      assert html =~ "grid-template-columns: repeat(5, minmax(0, 1fr))"
    end
  end

  describe "archive_stats_strip/1 — values" do
    test "renders the integer values for each counter cell" do
      html =
        render_strip(
          full_stats(%{
            total: 12,
            completed: 7,
            cancelled: 3,
            wontdo_duplicate: 2
          })
        )

      # The 24px tabular-numerics dd contains each value.
      assert html =~ ~r/>\s*12\s*</
      assert html =~ ~r/>\s*7\s*</
      assert html =~ ~r/>\s*3\s*</
      assert html =~ ~r/>\s*2\s*</
    end

    test "renders 0 when a counter bucket is empty" do
      html =
        render_strip(
          full_stats(%{
            total: 0,
            completed: 0,
            cancelled: 0,
            wontdo_duplicate: 0,
            avg_cycle_minutes: nil
          })
        )

      assert length(Regex.scan(~r/>\s*0\s*</, html)) >= 4
    end
  end

  describe "archive_stats_strip/1 — avg_cycle_minutes formatting" do
    test "renders an em-dash when avg_cycle_minutes is nil" do
      html = render_strip(full_stats(%{avg_cycle_minutes: nil}))
      assert html =~ ~r/data-archive-stats-cell="avg-cycle"[\s\S]*?>\s*—\s*</
    end

    test "renders 'Nm' when avg_cycle_minutes is under an hour" do
      html = render_strip(full_stats(%{avg_cycle_minutes: 47}))
      assert html =~ "47m"
    end

    test "renders 'Xh Ym' when avg_cycle_minutes spans hours and minutes" do
      html = render_strip(full_stats(%{avg_cycle_minutes: 161}))
      assert html =~ "2h 41m"
    end

    test "renders 'Nh' (no minutes suffix) when avg_cycle_minutes is a clean hour" do
      html = render_strip(full_stats(%{avg_cycle_minutes: 120}))
      assert html =~ ~r/>\s*2h\s*</
      refute html =~ "2h 0m"
    end

    test "renders '0m' when avg_cycle_minutes is exactly 0" do
      html = render_strip(full_stats(%{avg_cycle_minutes: 0}))
      assert html =~ "0m"
    end
  end

  describe "archive_stats_strip/1 — tone tokens" do
    test "Completed cell uses the st-done ink token" do
      html = render_strip(full_stats(%{}))
      assert html =~ ~r/data-archive-stats-cell="completed"[\s\S]*?color: var\(--st-done\)/
    end

    test "Cancelled cell uses the st-blocked ink token" do
      html = render_strip(full_stats(%{}))

      assert html =~
               ~r/data-archive-stats-cell="cancelled"[\s\S]*?color: var\(--st-blocked\)/
    end

    test "neutral cells use the default --ink token for the value" do
      html = render_strip(full_stats(%{}))
      # The value dd is the second `color: var(...)` in each cell (the
      # first is the dt label which is always var(--ink-3)). Match the
      # 24px font-size that uniquely identifies the value dd.
      assert html =~
               ~r/data-archive-stats-cell="total"[\s\S]*?font-size: 24px[\s\S]*?color: var\(--ink\)/

      assert html =~
               ~r/data-archive-stats-cell="wontdo-duplicate"[\s\S]*?font-size: 24px[\s\S]*?color: var\(--ink\)/

      assert html =~
               ~r/data-archive-stats-cell="avg-cycle"[\s\S]*?font-size: 24px[\s\S]*?color: var\(--ink\)/
    end

    test "no hardcoded Tailwind greys leak into the markup" do
      html = render_strip(full_stats(%{}))
      refute html =~ "text-gray-"
      refute html =~ "bg-gray-"
      refute html =~ "bg-white"
    end
  end

  describe "archive_stats_strip/1 — labels" do
    test "renders the five English labels" do
      html = render_strip(full_stats(%{}))
      assert html =~ "Total archived"
      assert html =~ "Completed"
      assert html =~ "Cancelled"
      # HTML-escapes the apostrophe.
      assert html =~ "Won&#39;t do · duplicate"
      assert html =~ "Avg cycle · completed"
    end
  end
end
