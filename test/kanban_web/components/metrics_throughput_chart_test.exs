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
end
