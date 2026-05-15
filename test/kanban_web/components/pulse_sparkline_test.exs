defmodule KanbanWeb.PulseSparklineTest do
  @moduledoc """
  Contract tests for `KanbanWeb.PulseSparkline.pulse_sparkline/1` —
  the inline SVG sparkline used by the Boards index card.
  """
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.PulseSparkline

  describe "pulse_sparkline/1 — SVG envelope" do
    test "renders an svg with the default 88x22 dimensions" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <PulseSparkline.pulse_sparkline data={[1, 2, 3]} />
        """)

      assert html =~ ~s[<svg width="88" height="22"]
    end

    test "honors explicit width and height" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <PulseSparkline.pulse_sparkline data={[1, 2, 3]} width={120} height={30} />
        """)

      assert html =~ ~s[<svg width="120" height="30"]
    end
  end

  describe "pulse_sparkline/1 — points scaling" do
    test "places equally spaced points across the width for a known data array" do
      # 3 points across width 100, height 22:
      #   step = 100 / (3 - 1) = 50
      #   max  = max(2, 1) = 2
      #   y(v) = 22 - (v/2) * 20 - 1 = 21 - 10v
      # → (0, 21), (50, 11), (100, 1)
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <PulseSparkline.pulse_sparkline data={[0, 1, 2]} width={100} height={22} />
        """)

      assert html =~ ~s[points="0,21 50,11 100,1"]
    end

    test "data point gets a matching circle for each value" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <PulseSparkline.pulse_sparkline data={[0, 1, 2]} width={100} height={22} />
        """)

      assert html =~ ~s[cx="0" cy="21"]
      assert html =~ ~s[cx="50" cy="11"]
      assert html =~ ~s[cx="100" cy="1"]
    end
  end

  describe "pulse_sparkline/1 — color attribute" do
    test "applies the color to both polyline stroke and circle fills" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <PulseSparkline.pulse_sparkline data={[1, 2, 3]} color="#FF8800" />
        """)

      assert html =~ ~s[stroke="#FF8800"]
      assert html =~ ~s[fill="#FF8800"]
    end

    test "defaults to var(--ink-3) when color is not provided" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <PulseSparkline.pulse_sparkline data={[1, 2, 3]} />
        """)

      assert html =~ ~s[stroke="var(--ink-3)"]
      assert html =~ ~s[fill="var(--ink-3)"]
    end
  end

  describe "pulse_sparkline/1 — circle styling" do
    test "renders each circle with r=0.8 and opacity 0.5" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <PulseSparkline.pulse_sparkline data={[1, 2]} />
        """)

      assert html =~ ~s[r="0.8"]
      # Two data points → two opacity="0.5" circles
      assert html
             |> String.split(~s[opacity="0.5"])
             |> length() == 3
    end

    test "polyline opacity is 0.85 and stroke-width is 1.25" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <PulseSparkline.pulse_sparkline data={[1, 2, 3]} />
        """)

      assert html =~ ~s[opacity="0.85"]
      assert html =~ ~s[stroke-width="1.25"]
    end
  end

  describe "pulse_sparkline/1 — edge cases" do
    test "all-zeros data renders a flat horizontal line at the bottom" do
      # max clamps to 1; v/max = 0 for every point; y = height - 1
      # → with height 22, every y is 21
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <PulseSparkline.pulse_sparkline data={List.duplicate(0, 14)} width={88} height={22} />
        """)

      # All circles at y = 21
      assert html =~ ~s[cy="21"]
      # No higher position emitted
      refute html =~ ~s[cy="1"]
    end

    test "single-element data renders one point at x=0" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <PulseSparkline.pulse_sparkline data={[5]} width={100} height={22} />
        """)

      # Single point: v=5, max=5, y = 22 - 1 * 20 - 1 = 1
      assert html =~ ~s[points="0,1"]
      assert html =~ ~s[cx="0" cy="1"]
    end

    test "empty data renders just the svg envelope with no polyline points or circles" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <PulseSparkline.pulse_sparkline data={[]} />
        """)

      assert html =~ ~s[<svg]
      assert html =~ ~s[points=""]
      refute html =~ ~s[<circle]
    end

    test "very large values still scale to fit the height" do
      # All circles must stay within [1, height-1].
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <PulseSparkline.pulse_sparkline
          data={[1_000_000, 500_000, 0]}
          width={100}
          height={22}
        />
        """)

      # max = 1_000_000; v/max ∈ {1, 0.5, 0}; y ∈ {1, 11, 21}
      assert html =~ ~s[points="0,1 50,11 100,21"]
    end
  end
end
