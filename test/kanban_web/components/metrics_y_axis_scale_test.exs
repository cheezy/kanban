defmodule KanbanWeb.MetricsYAxisScaleTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.MetricsYAxisScale

  doctest KanbanWeb.MetricsYAxisScale

  describe "scale/1 rounding" do
    test "rounds a peak of 37 up to a nice maximum with round ticks" do
      assert %{max: 40, ticks: [0, 10, 20, 30, 40]} = MetricsYAxisScale.scale(37)
    end

    test "gives a small peak readable small-value ticks rather than a 150 floor" do
      scale = MetricsYAxisScale.scale(5)

      assert scale == %{max: 5, ticks: [0, 1, 2, 3, 4, 5]}
      refute scale.max == 150
    end

    test "gives a large peak readable large-value ticks" do
      assert %{max: 2500, ticks: [0, 500, 1000, 1500, 2000, 2500]} =
               MetricsYAxisScale.scale(2400)
    end

    test "keeps the maximum at the peak when the peak is exactly on a step boundary" do
      assert %{max: 100, ticks: [0, 20, 40, 60, 80, 100]} = MetricsYAxisScale.scale(100)
    end

    test "rounds up to the next step when the peak is just above a boundary" do
      assert %{max: 120, ticks: [0, 20, 40, 60, 80, 100, 120]} = MetricsYAxisScale.scale(101)
    end

    test "produces decimal ticks without long floating point tails for sub-unit peaks" do
      %{max: max, ticks: ticks} = MetricsYAxisScale.scale(1.8)

      assert ticks == [0, 0.5, 1.0, 1.5, 2.0]
      assert max == 2.0
    end
  end

  describe "scale/1 degenerate input" do
    test "a peak of zero yields a sane default scale without raising" do
      assert %{max: 4, ticks: [0, 1, 2, 3, 4]} = MetricsYAxisScale.scale(0)
    end

    test "an empty series yields a sane default scale without raising" do
      assert %{max: 4, ticks: [0, 1, 2, 3, 4]} = MetricsYAxisScale.scale([])
    end

    test "a series of all zeros yields the default scale" do
      assert %{max: 4, ticks: [0, 1, 2, 3, 4]} = MetricsYAxisScale.scale([0, 0, 0])
    end

    test "a negative peak falls back to the default scale rather than raising" do
      assert %{max: 4, ticks: [0, 1, 2, 3, 4]} = MetricsYAxisScale.scale(-10)
    end
  end

  describe "scale/1 with a series" do
    test "scales to the peak of the series" do
      assert MetricsYAxisScale.scale([12, 87, 40]) == MetricsYAxisScale.scale(87)
    end

    test "a single data point scales to that point" do
      assert MetricsYAxisScale.scale([37]) == MetricsYAxisScale.scale(37)
    end
  end

  describe "scale/1 invariants" do
    @peaks [
      1,
      2,
      5,
      7,
      13,
      37,
      60,
      99,
      100,
      101,
      150,
      260,
      999,
      1000,
      2400,
      87_654,
      0.001,
      0.4,
      3.7
    ]

    test "ticks always start at zero and end at the returned maximum" do
      for peak <- @peaks do
        %{max: max, ticks: ticks} = MetricsYAxisScale.scale(peak)

        assert List.first(ticks) == 0, "expected first tick to be 0 for peak #{peak}"
        assert List.last(ticks) == max, "expected last tick to equal max for peak #{peak}"
      end
    end

    test "ticks are evenly spaced" do
      for peak <- @peaks do
        %{ticks: ticks} = MetricsYAxisScale.scale(peak)

        gaps =
          ticks
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.map(fn [a, b] -> Float.round((b - a) / 1, 6) end)
          |> Enum.uniq()

        assert length(gaps) == 1,
               "expected one uniform gap for peak #{peak}, got #{inspect(gaps)}"
      end
    end

    test "the maximum is never below the data peak so bars never clip" do
      for peak <- @peaks do
        %{max: max} = MetricsYAxisScale.scale(peak)

        assert max >= peak, "expected max #{max} to cover peak #{peak}"
      end
    end

    test "step sizes follow the 1-2-5 progression across several orders of magnitude" do
      for peak <- @peaks do
        %{ticks: [_zero, step | _rest]} = MetricsYAxisScale.scale(peak)

        magnitude = :math.pow(10, Float.floor(:math.log10(step)))
        normalized = Float.round(step / magnitude, 6)

        assert normalized in [1.0, 2.0, 5.0],
               "expected a 1-2-5 step for peak #{peak}, got #{step}"
      end
    end

    # A tick may legitimately carry as many decimals as its own step needs — a
    # sub-milli scale steps by 0.0002 — so the tolerance is derived from the
    # step rather than hardcoded. What must never appear is a tick carrying
    # MORE precision than its step, which is how a float tail like
    # 0.30000000000000004 would show up.
    test "never returns a tick with more precision than its own step" do
      for peak <- @peaks do
        %{ticks: [_zero, step | _rest] = ticks} = MetricsYAxisScale.scale(peak)
        precision = step_precision(step)

        for tick <- ticks do
          assert tick == Float.round(tick / 1, precision),
                 "expected a tick within #{precision} decimals for peak #{peak}, " <>
                   "got #{inspect(tick)}"
        end
      end
    end
  end

  defp step_precision(step) when step >= 1, do: 0

  defp step_precision(step) do
    step |> :math.log10() |> Float.floor() |> abs() |> trunc()
  end
end
