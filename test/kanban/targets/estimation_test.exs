defmodule Kanban.Targets.EstimationTest do
  @moduledoc """
  Unit tests for `Kanban.Targets.Estimation` — pure estimated-completion math,
  no DB. Mirrors the standalone pure-module style of
  `Kanban.Targets.StatusTest` and the percentile edge-case coverage of
  `Kanban.Metrics.CalculationsTest`.
  """
  use ExUnit.Case, async: true

  alias Kanban.Targets.Estimation

  @today ~D[2026-07-17]
  @day 86_400

  describe "estimated_completion_date/3" do
    test "returns nil for an empty lead-time sample" do
      assert Estimation.estimated_completion_date([], 3, @today) == nil
    end

    test "returns nil when remaining is 0, even with a non-empty sample" do
      assert Estimation.estimated_completion_date([@day * 1.0], 0, @today) == nil
    end

    test "single-element sample: p50 is that element" do
      # p50 of [1 day] is 1 day; 3 remaining -> today + 3.
      assert Estimation.estimated_completion_date([@day * 1.0], 3, @today) ==
               Date.add(@today, 3)
    end

    test "interpolated p50 across the sample drives the projection" do
      # Leads of 1/2/4 days: rank = 0.5 * 2 = 1.0 -> exact middle element = 2.0
      # days; 2 remaining -> 4.0 days -> today + 4.
      leads = [@day * 1.0, @day * 2.0, @day * 4.0]

      assert Estimation.estimated_completion_date(leads, 2, @today) == Date.add(@today, 4)
    end

    test "fractional day products round up, never down" do
      # p50 of [1,2,3,4] days: rank = 1.5 -> 2 + 0.5 * (3 - 2) = 2.5 days;
      # 1 remaining -> 2.5 days -> ceil -> today + 3.
      leads = [@day * 1.0, @day * 2.0, @day * 3.0, @day * 4.0]

      assert Estimation.estimated_completion_date(leads, 1, @today) == Date.add(@today, 3)
    end

    test "a sub-day p50 with one remaining task still rounds up to tomorrow" do
      assert Estimation.estimated_completion_date([@day / 2], 1, @today) ==
               Date.add(@today, 1)
    end

    test "an all-zero-lead sample projects today (documented degenerate case)" do
      assert Estimation.estimated_completion_date([0.0, 0.0], 5, @today) == @today
    end

    test "unsorted samples are handled (percentile sorts internally)" do
      # Same [1,2,4]-day sample as above, shuffled: p50 -> 2.0 days -> today + 4.
      leads = [@day * 4.0, @day * 1.0, @day * 2.0]

      assert Estimation.estimated_completion_date(leads, 2, @today) == Date.add(@today, 4)
    end

    test "integer lead-time seconds work alongside floats" do
      assert Estimation.estimated_completion_date([@day, @day, @day], 2, @today) ==
               Date.add(@today, 2)
    end
  end
end
