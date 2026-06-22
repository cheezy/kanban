defmodule KanbanWeb.MetricsCycleTimeChartTest do
  @moduledoc """
  Tests for `KanbanWeb.MetricsCycleTimeChart.cycle_time_chart/1`.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.MetricsCycleTimeChart

  defp data(opts \\ []) do
    base = ~D[2026-05-01]
    minutes = Keyword.get(opts, :minutes, 60)

    for i <- 0..13 do
      %{date: Date.add(base, i), minutes: minutes}
    end
  end

  defp render_chart(data) do
    assigns = %{data: data}

    rendered_to_string(~H"""
    <MetricsCycleTimeChart.cycle_time_chart data={@data} />
    """)
  end

  describe "cycle_time_chart/1 — markers and structure" do
    test "renders the root marker" do
      assert render_chart(data()) =~ "data-metrics-cycle-time-chart"
    end

    test "renders the plot container with the fixed 180px height" do
      assert render_chart(data()) =~ "height: 180px"
    end

    test "renders 14 bars by default" do
      html = render_chart(data())
      assert length(Regex.scan(~r/data-metrics-cycle-time-bar(?!-)/, html)) == 14
    end

    test "renders 4 gridlines at 0 / 50 / 100 / 150" do
      html = render_chart(data())

      for tick <- [0, 50, 100, 150] do
        assert html =~ ~s(data-metrics-cycle-time-gridline="#{tick}")
        assert html =~ "#{tick}m"
      end
    end

    test "stamps each bar with its ISO date" do
      html = render_chart(data())
      assert html =~ "data-metrics-cycle-time-bar-date=\"2026-05-01\""
      assert html =~ "data-metrics-cycle-time-bar-date=\"2026-05-14\""
    end
  end

  describe "cycle_time_chart/1 — bar and colors" do
    test "the single cycle bar uses the stride-orange token" do
      html = render_chart(data())
      orange_segments = Regex.scan(~r/data-metrics-cycle-time-segment="cycle"/, html)
      assert length(orange_segments) == 14
      assert html =~ "background: var(--stride-orange)"
    end

    test "no agent/human split segments are rendered" do
      html = render_chart(data())
      assert Regex.scan(~r/data-metrics-cycle-time-segment="agent"/, html) == []
      assert Regex.scan(~r/data-metrics-cycle-time-segment="human"/, html) == []
      refute html =~ "var(--stride-violet)"
    end

    test "scales bar heights against the 150m baseline when values are smaller" do
      # 30m on a 150m scale → 30/150 * 170 = 34px
      html = render_chart(data(minutes: 30))
      assert html =~ "height: 34.0px"
    end

    test "scales the chart_max up when peak exceeds 150 so bars do not clip" do
      # If the median is 300, chart_max becomes 300; the 50m gridline
      # then sits at 50/300 = ~16.7% from the bottom.
      html = render_chart(data(minutes: 300))
      assert html =~ ~r/bottom: 16\.6\d+%/
      # The 150m gridline sits at exactly 50% rather than at the top edge.
      assert html =~ "bottom: 50.0%"
    end

    test "zero-minute entries render zero-height bars" do
      html = render_chart(data(minutes: 0))
      assert html =~ "height: 0.0px"
    end
  end

  describe "cycle_time_chart/1 — header and labels" do
    test "renders no agent/human legend" do
      html = render_chart(data())
      refute html =~ "Agent"
      refute html =~ "Human"
    end

    test "renders the title and subtitle" do
      html = render_chart(data())
      assert html =~ "Cycle time · daily median (min)"
      assert html =~ "last 14 days"
      refute html =~ "agent vs human"
    end

    test "renders a single-letter weekday label under each bar" do
      html = render_chart(data())
      # 2026-05-01 is a Friday — letter "F"
      assert html =~ ~r/>\s*F\s*</
      # 2026-05-02 is a Saturday — letter "S"
      assert html =~ ~r/>\s*S\s*</
    end
  end

  describe "cycle_time_chart/1 — degenerate data" do
    test "renders gridlines but no bars for an empty data list" do
      html = render_chart([])
      # The chart_max falls back to the 150m baseline (Enum.max default).
      assert html =~ "data-metrics-cycle-time-chart"
      assert html =~ ~s(data-metrics-cycle-time-gridline="150")
      assert Regex.scan(~r/data-metrics-cycle-time-bar(?!-)/, html) == []
    end
  end

  describe "cycle_time_chart/1 — accessibility and tokens" do
    test "no hardcoded Tailwind greys or daisyUI base colors" do
      html = render_chart(data())
      refute html =~ "text-gray-"
      refute html =~ "bg-gray-"
      refute html =~ "bg-white"
      refute html =~ "bg-base-100"
    end

    test "renders without :data containing exactly 14 entries (no length assumption)" do
      partial = Enum.take(data(), 3)
      html = render_chart(partial)
      assert length(Regex.scan(~r/data-metrics-cycle-time-bar(?!-)/, html)) == 3
    end
  end
end
