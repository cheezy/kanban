defmodule KanbanWeb.MetricsThroughputChartTest do
  @moduledoc """
  Tests for `KanbanWeb.MetricsThroughputChart.throughput_chart/1`.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.MetricsThroughputChart

  defp render_chart(series) do
    assigns = %{series: series}

    rendered_to_string(~H"""
    <MetricsThroughputChart.throughput_chart series={@series} />
    """)
  end

  # The "%b %-d" label for a point `days_ago` before today (the trailing window
  # the throughput chart derives its x-axis from).
  defp day_label(days_ago) do
    Date.utc_today() |> Date.add(-days_ago) |> Calendar.strftime("%b %-d")
  end

  describe "throughput_chart/1 — markers and structure" do
    test "renders the root marker" do
      assert render_chart([5, 6, 7]) =~ "data-metrics-throughput-chart"
    end

    test "renders the 140px-tall plot container" do
      assert render_chart([5, 6, 7]) =~ "height: 140px"
    end

    test "renders the inline SVG (no external script)" do
      html = render_chart([5, 6, 7])
      assert html =~ "<svg"
      refute html =~ "<script"
    end

    test "uses a 600x140 viewBox with preserveAspectRatio='none'" do
      html = render_chart([5, 6, 7])
      assert html =~ "viewBox=\"0 0 600 140\""
      assert html =~ "preserveAspectRatio=\"none\""
    end

    test "exposes the line and area path markers + per-point circles" do
      html = render_chart([8, 12, 9, 11, 14, 6, 10, 18, 13, 16, 19, 21, 17, 23])

      assert html =~ "data-metrics-throughput-area"
      assert html =~ "data-metrics-throughput-line"
      assert length(Regex.scan(~r/data-metrics-throughput-point/, html)) == 14
    end
  end

  describe "throughput_chart/1 — gradient + tokens" do
    test "renders the orange gradient with stop-opacity 0.25 → 0.0" do
      html = render_chart([5, 6, 7])
      assert html =~ "linearGradient"
      assert html =~ ~s(stop-opacity="0.25")
      assert html =~ ~s(stop-opacity="0.0")
    end

    test "fills the area path with the gradient via url(#metrics-throughput-grad)" do
      html = render_chart([5, 6, 7])
      assert html =~ "fill=\"url(#metrics-throughput-grad)\""
    end

    test "uses the orange oklch token (matching design source)" do
      html = render_chart([5, 6, 7])
      assert html =~ "oklch(68% 0.17 47)"
    end

    test "no hardcoded Tailwind greys or daisyUI base classes" do
      html = render_chart([5, 6, 7])
      refute html =~ "text-gray-"
      refute html =~ "bg-gray-"
      refute html =~ "bg-white"
      refute html =~ "bg-base-100"
    end
  end

  describe "throughput_chart/1 — header copy" do
    test "renders the title and the '14 days' subtitle" do
      html = render_chart([5, 6, 7])
      assert html =~ "Throughput · tasks completed per day"
      assert html =~ "14 days"
    end

    test "carries an aria-label for accessibility" do
      assert render_chart([5, 6, 7]) =~ ~s(aria-label="Throughput sparkline")
    end
  end

  describe "throughput_chart/1 — y-axis scale + per-day values" do
    test "renders the series peak value as a y-axis gridline" do
      html = render_chart([8, 12, 9, 11, 14, 6, 10, 18, 13, 16, 19, 21, 17, 23])
      assert html =~ ~s(data-metrics-throughput-gridline="23")
    end

    test "renders a zero baseline gridline" do
      assert render_chart([5, 6, 7]) =~ ~s(data-metrics-throughput-gridline="0")
    end

    test "renders one value label per day with each day's count" do
      html = render_chart([5, 6, 7])

      assert length(Regex.scan(~r/data-metrics-throughput-value-label/, html)) == 3
      assert html =~ ~r/>\s*5\s*</
      assert html =~ ~r/>\s*6\s*</
      assert html =~ ~r/>\s*7\s*</
    end

    test "an all-zero series renders without error and reads as 0" do
      html = render_chart([0, 0, 0])

      # Only the zero baseline gridline (no non-zero peak), and three "0" labels.
      assert html =~ ~s(data-metrics-throughput-gridline="0")
      assert length(Regex.scan(~r/data-metrics-throughput-value-label/, html)) == 3
    end

    test "a peak of one renders a 1-and-0 scale" do
      html = render_chart([1, 1, 1])
      assert html =~ ~s(data-metrics-throughput-gridline="1")
      assert html =~ ~s(data-metrics-throughput-gridline="0")
    end

    test "a single non-zero day still renders its value and a peak gridline" do
      html = render_chart([7])
      assert html =~ ~s(data-metrics-throughput-gridline="7")
      assert length(Regex.scan(~r/data-metrics-throughput-value-label/, html)) == 1
    end

    test "value labels and gridlines use tabular-nums and theme tokens" do
      html = render_chart([5, 6, 7])
      assert html =~ "font-variant-numeric: tabular-nums"
      assert html =~ "var(--ink-3)"
      assert html =~ "var(--ink-4)"
      refute html =~ "text-gray-"
    end
  end

  describe "compute_geometry/1 — pure math" do
    test "returns empty paths and points for an empty series" do
      result = MetricsThroughputChart.compute_geometry([])
      assert result.points == []
      assert result.line_path == ""
      # The area path is still a degenerate triangle at the baseline.
      assert String.starts_with?(result.area_path, "M0,130")
    end

    test "places a single-point series at x=0 (no division by zero)" do
      result = MetricsThroughputChart.compute_geometry([7])
      assert [{x, _y}] = result.points
      assert x == +0.0
    end

    test "spaces points evenly across the 600-unit viewBox" do
      result = MetricsThroughputChart.compute_geometry([1, 1, 1, 1, 1])
      xs = Enum.map(result.points, &elem(&1, 0))
      assert xs == [0.0, 150.0, 300.0, 450.0, 600.0]
    end

    test "places the peak value at the top of the plot area" do
      # The first point is the peak (3). Top-of-plot y = top_padding (20).
      result = MetricsThroughputChart.compute_geometry([3, 1, 1])
      [{first_x, top_y} | _] = result.points
      assert first_x == +0.0
      assert top_y == 20.0
    end

    test "places zero values on the baseline" do
      # baseline_y = view_h(140) - bottom_padding(10) = 130
      result = MetricsThroughputChart.compute_geometry([0, 0, 0])
      assert Enum.all?(result.points, fn {_x, y} -> y == 130.0 end)
    end

    test "line path starts with M and contains one L-segment per non-first point" do
      result = MetricsThroughputChart.compute_geometry([1, 2, 3])
      assert String.starts_with?(result.line_path, "M")
      assert length(Regex.scan(~r/ L/, result.line_path)) == 2
    end

    test "area path closes back to the baseline at the last x" do
      result = MetricsThroughputChart.compute_geometry([1, 2, 3])
      assert String.ends_with?(result.area_path, "L600.0,130 Z")
    end
  end

  describe "throughput_chart/1 — x-axis date labels" do
    test "renders one date label per point for a short series, ending today" do
      html = render_chart([5, 6, 7])

      assert html =~ "data-metrics-throughput-axis"
      assert length(Regex.scan(~r/data-metrics-throughput-date-label/, html)) == 3
      # Trailing window ending today: oldest point is today-2, newest is today.
      assert html =~ day_label(2)
      assert html =~ day_label(0)
    end

    test "anchors a label on the first and last points" do
      html = render_chart([1, 2, 3, 4, 5])

      # The x-axis labels clamp the endpoints with translateX(0) / translateX(-100%);
      # unlike the value labels' translate(.., -2px), these are unique to the axis row.
      assert html =~ "translateX(0)"
      assert html =~ "translateX(-100%)"
    end

    test "labels every point (no thinning) at the 7-day window" do
      html = render_chart(List.duplicate(1, 7))
      assert length(Regex.scan(~r/data-metrics-throughput-date-label/, html)) == 7
    end

    test "thins a 30-day window to an endpoint-anchored subset" do
      html = render_chart(List.duplicate(1, 30))
      count = length(Regex.scan(~r/data-metrics-throughput-date-label/, html))

      assert count == 8
      assert count < 30
      # First (today-29) and last (today) are always retained.
      assert html =~ day_label(29)
      assert html =~ day_label(0)
    end

    test "thins a 90-day window to at most the label cap, keeping the endpoints" do
      html = render_chart(List.duplicate(1, 90))
      count = length(Regex.scan(~r/data-metrics-throughput-date-label/, html))

      assert count == 8
      assert html =~ day_label(89)
      assert html =~ day_label(0)
    end

    test "date labels use the dimmer theme token and tabular-nums" do
      html = render_chart([5, 6, 7])

      assert html =~ "var(--ink-4)"
      assert html =~ "font-variant-numeric: tabular-nums"
      refute html =~ "text-gray-"
    end

    test "an empty series renders the axis row with no date labels" do
      html = render_chart([])

      assert html =~ "data-metrics-throughput-axis"
      assert Regex.scan(~r/data-metrics-throughput-date-label/, html) == []
    end

    test "a single-point series renders today's date as the only label" do
      html = render_chart([7])

      assert length(Regex.scan(~r/data-metrics-throughput-date-label/, html)) == 1
      assert html =~ day_label(0)
    end

    test "does not thin the per-day value labels — only the x-axis row" do
      html = render_chart(List.duplicate(1, 30))

      # Value labels remain one-per-day; only the date axis is thinned.
      assert length(Regex.scan(~r/data-metrics-throughput-value-label/, html)) == 30
    end
  end
end
