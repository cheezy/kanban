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

  # The lead-time configuration: the same component with every series-specific
  # attribute supplied, which is how the workspace page renders the second
  # series without a cloned module.
  defp render_lead_chart(data) do
    assigns = %{data: data}

    rendered_to_string(~H"""
    <MetricsCycleTimeChart.cycle_time_chart
      data={@data}
      color="var(--stride-violet)"
      title="Lead time · daily median (min)"
      marker_prefix="lead-time"
      series_name="lead"
    />
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

  # W1720: a least-squares trend line overlays the bars so the direction of
  # travel is readable without comparing individual days.
  describe "cycle_time_chart/1 — trend line" do
    defp trend_line(html) do
      [line] = Regex.run(~r/<line data-metrics-cycle-time-trend-line[^>]*>/, html)
      line
    end

    defp rising_data(count) do
      base = ~D[2026-05-01]

      for i <- 0..(count - 1) do
        %{date: Date.add(base, i), minutes: 10 + i * 10}
      end
    end

    test "renders a trend line for a series of two or more points" do
      html = render_chart(rising_data(14))

      assert html =~ "data-metrics-cycle-time-trend"
      assert html =~ "data-metrics-cycle-time-trend-line"
      assert html =~ "stroke-dasharray"
    end

    test "renders a trend line for exactly two points" do
      html = render_chart(rising_data(2))

      assert html =~ "data-metrics-cycle-time-trend-line"
    end

    test "renders no trend line for a single data point" do
      html = render_chart([%{date: ~D[2026-05-01], minutes: 30}])

      refute html =~ "data-metrics-cycle-time-trend"
    end

    test "renders no trend line for an empty series and does not raise" do
      html = render_chart([])

      assert html =~ "data-metrics-cycle-time-chart"
      refute html =~ "data-metrics-cycle-time-trend"
    end

    test "a rising series slopes upward and a falling series slopes downward" do
      rising = render_chart(rising_data(14))
      falling = 14 |> rising_data() |> Enum.reverse() |> render_chart()

      # y is measured from the top in the overlay, so a smaller y2 than y1
      # is a line travelling upward across the plot.
      assert [[_, y1, y2]] = Regex.scan(~r/y1="([\d.]+)"[\s\S]*?y2="([\d.]+)"/, rising)
      assert String.to_float(y2) < String.to_float(y1)

      assert [[_, fy1, fy2]] = Regex.scan(~r/y1="([\d.]+)"[\s\S]*?y2="([\d.]+)"/, falling)
      assert String.to_float(fy2) > String.to_float(fy1)
    end

    test "a flat series renders a level trend line" do
      flat = for i <- 0..13, do: %{date: Date.add(~D[2026-05-01], i), minutes: 20}
      html = render_chart(flat)

      assert [[_, y1, y2]] = Regex.scan(~r/y1="([\d.]+)"[\s\S]*?y2="([\d.]+)"/, html)
      assert_in_delta String.to_float(y1), String.to_float(y2), 0.01
    end

    test "the trend overlay shares the bars' baseline and span, not the plot floor" do
      # A bar column reserves the day-label row below the bar, so a bar's
      # zero is 16px (12px label + 4px gap) above the plot floor. The overlay
      # must start from that same baseline and cover the same 170px bar area,
      # or the line renders offset from the bars it tracks.
      html = render_chart(rising_data(14))

      assert html =~ "bottom: 16px"
      assert html =~ "height: 170px"
      assert html =~ "height: 12px; line-height: 12px"
    end

    test "the trend endpoints are inset to the first and last bar centres" do
      # 14 bars, so the first centre is at 0.5/14 and the last at 13.5/14 of
      # the width - not the plot edges, which would overhang by half a bar.
      html = render_chart(rising_data(14))

      assert html =~ ~s(x1="3.57")
      assert html =~ ~s(x2="96.43")
    end

    test "a day with no median contributes zero without shifting the other days" do
      sparse = [
        %{date: ~D[2026-05-01], minutes: 10},
        %{date: ~D[2026-05-02], minutes: nil},
        %{date: ~D[2026-05-03], minutes: 30}
      ]

      zeroed = [
        %{date: ~D[2026-05-01], minutes: 10},
        %{date: ~D[2026-05-02], minutes: 0},
        %{date: ~D[2026-05-03], minutes: 30}
      ]

      assert trend_line(render_chart(sparse)) == trend_line(render_chart(zeroed))
    end

    test "the trend line is positioned against the same maximum as the bars" do
      # A flat 20-minute series scales to a 20m maximum, so the trend sits
      # at the top of the plot — y = 0 — exactly where the full-height bars
      # end.
      flat = for i <- 0..13, do: %{date: Date.add(~D[2026-05-01], i), minutes: 20}
      html = render_chart(flat)

      assert html =~ ~s(data-metrics-cycle-time-gridline="20")
      assert html =~ "height: 170.0px"
      assert html =~ ~s(y1="0.0")
      assert html =~ ~s(y2="0.0")
    end

    test "an extrapolation below zero is pinned to the plot floor" do
      # 300/200/0/0 fits slope -110, intercept 290, so the line projects to
      # -40 at the last point. It must land exactly on the floor (y = 100)
      # rather than below it.
      steep = [
        %{date: ~D[2026-05-01], minutes: 300},
        %{date: ~D[2026-05-02], minutes: 200},
        %{date: ~D[2026-05-03], minutes: 0},
        %{date: ~D[2026-05-04], minutes: 0}
      ]

      html = render_chart(steep)

      assert [[_, y1, y2]] = Regex.scan(~r/y1="([\d.]+)"[\s\S]*?y2="([\d.]+)"/, html)
      assert y2 == "100.0"
      # 290 of a 300-minute maximum, so the start is near the plot top.
      assert_in_delta String.to_float(y1), 3.33, 0.01
    end

    test "an extrapolation above the maximum is pinned to the plot top" do
      # 50/100/90/100 fits slope 14, intercept 64, projecting to 106 at the
      # last point against a derived 100-minute maximum. It must land exactly
      # on the top (y = 0) rather than above it.
      overshooting = [
        %{date: ~D[2026-05-01], minutes: 50},
        %{date: ~D[2026-05-02], minutes: 100},
        %{date: ~D[2026-05-03], minutes: 90},
        %{date: ~D[2026-05-04], minutes: 100}
      ]

      html = render_chart(overshooting)

      assert html =~ ~s(data-metrics-cycle-time-gridline="100")

      assert [[_, y1, y2]] = Regex.scan(~r/y1="([\d.]+)"[\s\S]*?y2="([\d.]+)"/, html)
      assert y2 == "0.0"
      # 64 of a 100-minute maximum leaves the start inside the plot.
      assert_in_delta String.to_float(y1), 36.0, 0.01
    end

    test "the trend line uses a theme token rather than a hardcoded color" do
      html = render_chart(rising_data(14))

      assert html =~ "stroke=\"var(--ink-4)\""
      refute html =~ "stroke=\"#"
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

  # W1722: the component is parameterized so one module renders both the cycle
  # and lead series. Every attribute defaults to its cycle value, which is what
  # the whole suite above proves by passing unchanged.
  describe "cycle_time_chart/1 — parameterized series" do
    test "with no color attribute supplied the bar keeps the cycle orange token" do
      html = render_chart(data())

      assert html =~ "background: var(--stride-orange)"
      refute html =~ "var(--stride-violet)"
    end

    test "a supplied color drives the bar and the default token disappears" do
      html = render_lead_chart(data())

      assert html =~ "background: var(--stride-violet)"
      refute html =~ "var(--stride-orange)"
    end

    test "the color is a CSS custom property reference, never a raw literal" do
      html = render_lead_chart(data())

      # Raw hex/oklch literals in a style attribute would break the dark-mode
      # contract, which is exactly why the color is passed as a token.
      refute html =~ ~r/background: #[0-9a-fA-F]{3,8}/
      refute html =~ ~r/background: oklch\(/
    end

    test "with no marker prefix supplied the existing cycle markers are emitted" do
      html = render_chart(data())

      assert html =~ "data-metrics-cycle-time-chart"
      assert html =~ "data-metrics-cycle-time-plot"
      assert html =~ ~s(data-metrics-cycle-time-segment="cycle")
      refute html =~ "data-metrics-lead-time-"
    end

    test "a supplied marker prefix derives every marker the component emits" do
      html = render_lead_chart(data())

      for suffix <- ~w(chart plot gridline bar bar-date segment trend trend-line) do
        assert html =~ "data-metrics-lead-time-#{suffix}"
      end

      # No marker leaks the cycle prefix, so two charts on one page stay
      # unambiguous to both tests and tooling.
      refute html =~ "data-metrics-cycle-time-"
    end

    test "the segment marker carries the supplied series name" do
      html = render_lead_chart(data())

      assert length(Regex.scan(~r/data-metrics-lead-time-segment="lead"/, html)) == 14
      refute html =~ ~s(data-metrics-lead-time-segment="cycle")
    end

    test "with no title supplied the existing cycle title renders" do
      assert render_chart(data()) =~ "Cycle time · daily median (min)"
    end

    test "a supplied title replaces it and the default disappears" do
      html = render_lead_chart(data())

      assert html =~ "Lead time · daily median (min)"
      refute html =~ "Cycle time · daily median (min)"
    end

    test "the subtitle still reflects the window in both configurations" do
      assert render_chart(data()) =~ "last 14 days"
      assert render_lead_chart(data()) =~ "last 14 days"
    end

    test "the tick unit defaults to minutes and is overridable" do
      assert render_chart(data(minutes: 60)) =~ "60m"

      assigns = %{data: data(minutes: 60)}

      html =
        rendered_to_string(~H"""
        <MetricsCycleTimeChart.cycle_time_chart data={@data} tick_unit="h" />
        """)

      assert html =~ "60h"
      refute html =~ "60m"
    end

    test "the auto-fitting rounded scale behaves identically in both configurations" do
      cycle = render_chart(data(minutes: 12))
      lead = render_lead_chart(data(minutes: 12))

      # Peak 12 rounds up to a 15m maximum in 5m steps in both, and the bar
      # fills the same 12/15 * 170 = 136px.
      assert cycle =~ ~s(data-metrics-cycle-time-gridline="15")
      assert lead =~ ~s(data-metrics-lead-time-gridline="15")
      assert cycle =~ "height: 136.0px"
      assert lead =~ "height: 136.0px"
    end

    test "the trend line renders in both configurations" do
      rising = for i <- 0..13, do: %{date: Date.add(~D[2026-05-01], i), minutes: 10 + i * 10}

      cycle = render_chart(rising)
      lead = render_lead_chart(rising)

      assert cycle =~ "data-metrics-cycle-time-trend-line"
      assert lead =~ "data-metrics-lead-time-trend-line"

      # The regression is identical for identical data — only the markers move.
      assert [[_, cy1, cy2]] = Regex.scan(~r/y1="([\d.]+)"[\s\S]*?y2="([\d.]+)"/, cycle)
      assert [[_, ly1, ly2]] = Regex.scan(~r/y1="([\d.]+)"[\s\S]*?y2="([\d.]+)"/, lead)
      assert {cy1, cy2} == {ly1, ly2}
    end

    test "the trend line keeps its theme token in the parameterized configuration" do
      rising = for i <- 0..13, do: %{date: Date.add(~D[2026-05-01], i), minutes: 10 + i * 10}
      html = render_lead_chart(rising)

      assert html =~ "stroke=\"var(--ink-4)\""
      refute html =~ "stroke=\"#"
    end

    test "an empty series renders the empty-state axis and no bars in either configuration" do
      cycle = render_chart([])
      lead = render_lead_chart([])

      assert cycle =~ ~s(data-metrics-cycle-time-gridline="4")
      assert lead =~ ~s(data-metrics-lead-time-gridline="4")
      assert Regex.scan(~r/data-metrics-lead-time-bar(?!-)/, lead) == []
      refute lead =~ "data-metrics-lead-time-trend"
    end

    test "an all-zero series renders zero-height bars in either configuration" do
      lead = render_lead_chart(data(minutes: 0))

      assert lead =~ ~s(data-metrics-lead-time-gridline="4")
      assert lead =~ "height: 0.0px"
      assert length(Regex.scan(~r/data-metrics-lead-time-bar(?!-)/, lead)) == 14
    end

    test "neither configuration emits hardcoded Tailwind greys or daisyUI base colors" do
      for html <- [render_chart(data()), render_lead_chart(data())] do
        refute html =~ "text-gray-"
        refute html =~ "bg-gray-"
        refute html =~ "bg-white"
        refute html =~ "bg-base-100"
      end
    end

    test "a title needing escaping is escaped rather than injected as markup" do
      assigns = %{data: data(), title: "<script>alert(1)</script>"}

      html =
        rendered_to_string(~H"""
        <MetricsCycleTimeChart.cycle_time_chart data={@data} title={@title} />
        """)

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end

    # The marker prefix lands in an attribute NAME, the one position HEEx
    # cannot escape: whitespace would close the marker and open a second,
    # caller-chosen attribute. The component rejects it outright rather than
    # relying on callers never passing one.
    test "a marker prefix outside the safe charset raises rather than injecting an attribute" do
      for bad <- ["evil\" onload=\"alert(1)", "has space", "UPPER", "under_score", ""] do
        assigns = %{data: data(), prefix: bad}

        assert_raise ArgumentError, ~r/marker_prefix must match/, fn ->
          rendered_to_string(~H"""
          <MetricsCycleTimeChart.cycle_time_chart data={@data} marker_prefix={@prefix} />
          """)
        end
      end
    end

    test "a color naming a token that does not exist renders inertly without raising" do
      assigns = %{data: data()}

      html =
        rendered_to_string(~H"""
        <MetricsCycleTimeChart.cycle_time_chart data={@data} color="var(--does-not-exist)" />
        """)

      # The browser falls back to no background; the component does not guess
      # or raise. The bars and scale still render.
      assert html =~ "background: var(--does-not-exist)"
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
