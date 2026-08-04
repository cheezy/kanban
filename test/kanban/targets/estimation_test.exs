defmodule Kanban.Targets.EstimationTest do
  @moduledoc """
  Unit tests for `Kanban.Targets.Estimation` — pure estimated-completion math,
  no DB. Mirrors the standalone pure-module style of
  `Kanban.Targets.StatusTest` and the percentile edge-case coverage of
  `Kanban.Metrics.CalculationsTest`.

  The anchor is an *instant* (D212). Several cases below turn on the time of
  day, so `@now` is deliberately mid-morning: it is the anchor at which the
  reported symptom (a 35/36 target estimating tomorrow at 08:00) reproduced.
  """
  use ExUnit.Case, async: true

  alias Kanban.Targets.Estimation

  @now ~U[2026-07-17 08:00:00Z]
  @today ~D[2026-07-17]
  @day 86_400

  describe "estimated_completion_date/3" do
    test "returns nil for an empty lead-time sample" do
      assert Estimation.estimated_completion_date([], 3, @now) == nil
    end

    test "returns nil when remaining is 0, even with a non-empty sample" do
      assert Estimation.estimated_completion_date([@day * 1.0], 0, @now) == nil
    end

    test "single-element sample: p50 is that element" do
      # p50 of [1 day] is 1 day; 3 remaining -> 3 days on from 08:00 -> today + 3.
      assert Estimation.estimated_completion_date([@day * 1.0], 3, @now) ==
               Date.add(@today, 3)
    end

    test "interpolated p50 across the sample drives the projection" do
      # Leads of 1/2/4 days: rank = 0.5 * 2 = 1.0 -> exact middle element = 2.0
      # days; 2 remaining -> 4.0 days -> today + 4.
      leads = [@day * 1.0, @day * 2.0, @day * 4.0]

      assert Estimation.estimated_completion_date(leads, 2, @now) == Date.add(@today, 4)
    end

    test "D212: one remaining task that fits inside today estimates TODAY" do
      # A 12-hour median with one task left, anchored at 08:00, finishes at
      # 20:00 the SAME day. The old whole-day ceil/1 reported tomorrow here --
      # this is the reported defect, reduced to its smallest form.
      assert Estimation.estimated_completion_date([@day / 2], 1, @now) == @today
    end

    test "D212: the same projection from late in the day crosses into tomorrow" do
      # Identical sample and remaining count as the case above; only the time of
      # day differs. 18:00 + 12h lands at 06:00 tomorrow. This is the other half
      # of the fix -- the estimate must still roll forward, for the right reason.
      late = ~U[2026-07-17 18:00:00Z]

      assert Estimation.estimated_completion_date([@day / 2], 1, late) == Date.add(@today, 1)
    end

    test "a fractional day product lands on the calendar day the projection falls in" do
      # p50 of [1,2,3,4] days: rank = 1.5 -> 2 + 0.5 * (3 - 2) = 2.5 days;
      # 1 remaining -> 2.5 days on from 08:00 -> 20:00 on the 19th.
      # The old math ceil'd 2.5 days to 3 and reported the 20th.
      leads = [@day * 1.0, @day * 2.0, @day * 3.0, @day * 4.0]

      assert Estimation.estimated_completion_date(leads, 1, @now) == ~D[2026-07-19]
    end

    test "the remaining count paces the projection across the day boundary" do
      # One 6-hour-median fixture, two counts: 2 tasks (12h) still fits inside
      # today from 08:00; 3 tasks (18h) does not.
      six_hours = [@day / 4]

      assert Estimation.estimated_completion_date(six_hours, 2, @now) == @today
      assert Estimation.estimated_completion_date(six_hours, 3, @now) == Date.add(@today, 1)
    end

    test "an all-zero-lead sample projects today (documented degenerate case)" do
      # Anchored at the last second of the day to prove the degenerate case is
      # not merely passing because there was room left in it.
      last_second = ~U[2026-07-17 23:59:59Z]

      assert Estimation.estimated_completion_date([0.0, 0.0], 5, last_second) == @today
    end

    test "a projection landing exactly at midnight belongs to the new day" do
      # 12:00 + exactly 12h = 00:00:00 on the 18th. The local day is the
      # half-open interval [00:00:00, 24:00:00), so this is the 18th.
      noon = ~U[2026-07-17 12:00:00Z]

      assert Estimation.estimated_completion_date([43_200.0], 1, noon) == ~D[2026-07-18]
    end

    test "sub-second slack rounds up, never down, at the day boundary" do
      # 43_199.2s short of midnight: ceil/1 gives 43_200 -> exactly midnight ->
      # the 18th. round/1 would give 43_199 -> 23:59:59 -> the 17th, pulling the
      # estimate a whole calendar day earlier than the math supports.
      noon = ~U[2026-07-17 12:00:00Z]

      assert Estimation.estimated_completion_date([43_199.2], 1, noon) == ~D[2026-07-18]
    end

    test "a whole-day product is time-of-day invariant" do
      # Documents why the DB-level fixtures elsewhere (all whole-day leads) kept
      # their expected values through this change: a whole number of days lands
      # at the same wall time N days on, from any anchor.
      start_of_day = ~U[2026-07-17 00:00:00Z]
      late = ~U[2026-07-17 23:00:00Z]

      assert Estimation.estimated_completion_date([@day * 1.0], 2, start_of_day) ==
               Date.add(@today, 2)

      assert Estimation.estimated_completion_date([@day * 1.0], 2, late) == Date.add(@today, 2)
    end

    test "the calendar day is read in the anchor's own zone, not UTC" do
      # 20:00 in Edmonton is already the NEXT day in UTC. A one-hour projection
      # finishes at 21:00 local, still the 17th locally -- the viewer's day is
      # what the badge must show.
      local = DateTime.new!(~D[2026-07-17], ~T[20:00:00], "America/Edmonton")

      result = Estimation.estimated_completion_date([3_600.0], 1, local)
      utc_day = local |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_date()

      assert result == ~D[2026-07-17]
      refute result == utc_day
    end

    test "unsorted samples are handled (percentile sorts internally)" do
      # Same [1,2,4]-day sample as above, shuffled: p50 -> 2.0 days -> today + 4.
      leads = [@day * 4.0, @day * 1.0, @day * 2.0]

      assert Estimation.estimated_completion_date(leads, 2, @now) == Date.add(@today, 4)
    end

    test "integer lead-time seconds work alongside floats" do
      assert Estimation.estimated_completion_date([@day, @day, @day], 2, @now) ==
               Date.add(@today, 2)
    end
  end
end
