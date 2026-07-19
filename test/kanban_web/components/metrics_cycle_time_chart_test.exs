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

    # Was: "renders 4 gridlines at 0 / 50 / 100 / 150". The ticks are no
    # longer hardcoded — they are derived from the data, so a 60-minute
    # series scales to 0 / 20 / 40 / 60 instead.
    test "renders gridlines derived from the data rather than a fixed list" do
      html = render_chart(data(minutes: 60))

      for tick <- [0, 20, 40, 60] do
        assert html =~ ~s(data-metrics-cycle-time-gridline="#{tick}")
        assert html =~ "#{tick}m"
      end

      refute html =~ ~s(data-metrics-cycle-time-gridline="150")
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

    # Was: "scales bar heights against the 150m baseline when values are
    # smaller", which asserted 30/150 * 170 = 34px — a bar filling a fifth
    # of the plot. The scale now fits the data (30m rounds to a 30m max),
    # so the same series fills the plot instead.
    test "scales bar heights against the derived maximum rather than a 150m baseline" do
      html = render_chart(data(minutes: 30))

      assert html =~ "height: 170.0px"
      refute html =~ "height: 34.0px"
    end

    # Was: "scales the chart_max up when peak exceeds 150 so bars do not
    # clip". The maximum still covers the peak, but the ticks now travel
    # with it instead of bunching in the bottom half of the plot.
    test "renders labelled gridlines reaching the top of the plot when the peak exceeds 150" do
      html = render_chart(data(minutes: 300))

      # The top tick labels the peak and sits at the top of the plot.
      assert html =~ ~s(data-metrics-cycle-time-gridline="300")
      assert html =~ "bottom: 100.0%"
      # Bars still do not clip.
      assert html =~ "height: 170.0px"
      # No tick bunched at the old 50/300 = 16.7% position.
      refute html =~ ~r/bottom: 16\.6\d+%/
    end

    test "a small-value series is not floored at 150 and fills a readable share of the plot" do
      html = render_chart(data(minutes: 12))

      # Peak 12 rounds up to a 15m maximum in 5m steps.
      assert html =~ ~s(data-metrics-cycle-time-gridline="15")
      refute html =~ ~s(data-metrics-cycle-time-gridline="150")

      # 12/15 * 170 = 136px — over two thirds of the plot, not a sliver.
      assert html =~ "height: 136.0px"
    end

    test "a series peaking exactly at the old 150 boundary still scales cleanly" do
      html = render_chart(data(minutes: 150))

      for tick <- [0, 50, 100, 150] do
        assert html =~ ~s(data-metrics-cycle-time-gridline="#{tick}")
      end

      assert html =~ "height: 170.0px"
    end

    test "one large outlier sets the scale without clipping the smaller bars" do
      [first | rest] = data(minutes: 10)
      html = render_chart([%{first | minutes: 200} | rest])

      # The outlier drives the maximum to 200 and fills the plot.
      assert html =~ ~s(data-metrics-cycle-time-gridline="200")
      assert html =~ "height: 170.0px"
      # The 10m bars remain visible at 10/200 * 170 = 8.5px.
      assert html =~ "height: 8.5px"
    end

    test "gridline positions and bar heights are computed from the same maximum" do
      html = render_chart(data(minutes: 40))

      # Peak 40 rounds to a 40m maximum in 10m steps, so the top tick is
      # at 100% and the full-height bar is the full bar area.
      assert html =~ ~s(data-metrics-cycle-time-gridline="40")
      assert html =~ "bottom: 100.0%"
      assert html =~ "bottom: 50.0%"
      assert html =~ "height: 170.0px"
    end

    # The scale helper is deliberately unit-agnostic, so a peak below four
    # minutes steps in half-minutes rather than being forced onto whole
    # minutes. Pinned here because it is the path that requires chart_max
    # to be a number rather than strictly an integer.
    test "a sub-four-minute peak scales in fractional steps and still fills the plot" do
      html = render_chart(data(minutes: 2))

      assert html =~ ~s(data-metrics-cycle-time-gridline="0.5")
      assert html =~ "0.5m"
      assert html =~ ~s(data-metrics-cycle-time-gridline="2.0")
      assert html =~ "height: 170.0px"
    end

    test "a single data point scales to that point" do
      html = render_chart([%{date: ~D[2026-05-01], minutes: 37}])

      assert html =~ ~s(data-metrics-cycle-time-gridline="40")
      assert length(Regex.scan(~r/data-metrics-cycle-time-bar(?!-)/, html)) == 1
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
    # Was pinned to the 150m baseline. The empty case now falls back to
    # the scale helper's documented empty-state axis instead.
    test "renders gridlines but no bars for an empty data list" do
      html = render_chart([])

      assert html =~ "data-metrics-cycle-time-chart"
      assert html =~ ~s(data-metrics-cycle-time-gridline="4")
      refute html =~ ~s(data-metrics-cycle-time-gridline="150")
      assert Regex.scan(~r/data-metrics-cycle-time-bar(?!-)/, html) == []
    end

    test "renders the empty-state axis without raising when every value is zero" do
      html = render_chart(data(minutes: 0))

      assert html =~ ~s(data-metrics-cycle-time-gridline="4")
      assert html =~ "height: 0.0px"
      assert length(Regex.scan(~r/data-metrics-cycle-time-bar(?!-)/, html)) == 14
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
