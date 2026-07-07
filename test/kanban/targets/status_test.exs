defmodule Kanban.Targets.StatusTest do
  # Pure derivation — no DB, so plain ExUnit (not Kanban.DataCase) and async.
  use ExUnit.Case, async: true

  alias Kanban.Targets.DeliveryTarget
  alias Kanban.Targets.Status

  # Builds a plain %DeliveryTarget{} struct (no DB) with an explicit creation
  # date (inserted_at is :utc_datetime_usec) and target_date.
  defp target(created_on, target_date) do
    %DeliveryTarget{
      inserted_at: DateTime.new!(created_on, ~T[00:00:00.000000], "Etc/UTC"),
      target_date: target_date
    }
  end

  # Convenience builder for the per-goal progress maps.
  defp goal(completed, total, complete?) do
    %{completed_children: completed, total_children: total, goal_complete?: complete?}
  end

  describe "derive/3 :complete" do
    test "all member goals complete -> :complete, even past the target date" do
      # Completion beats missed: today (Feb 1) is well past target (Jan 10),
      # but every goal is complete, so :complete wins by branch precedence.
      t = target(~D[2026-01-01], ~D[2026-01-10])
      goals = [goal(3, 3, true), goal(0, 0, true)]

      assert Status.derive(t, goals, ~D[2026-02-01]) == :complete
    end
  end

  describe "derive/3 :missed" do
    test "past the target date and not complete -> :missed" do
      # today (Jan 20) is strictly after target (Jan 10); goal is incomplete.
      t = target(~D[2026-01-01], ~D[2026-01-10])
      goals = [goal(1, 3, false)]

      assert Status.derive(t, goals, ~D[2026-01-20]) == :missed
    end

    test "today == target_date is NOT past, so not :missed" do
      # window = diff(Jan 11, Jan 01) = 10; today == target -> elapsed = 10/10 = 1.0.
      # work = 9/10 = 0.9; gap = 1.0 - 0.9 = 0.1, which is <= 0.15 -> :on_track.
      # Date.compare(today, target) == :eq (not :gt), so the target is not missed.
      t = target(~D[2026-01-01], ~D[2026-01-11])
      goals = [goal(9, 10, false)]

      assert Status.derive(t, goals, ~D[2026-01-11]) == :on_track
    end
  end

  describe "derive/3 :at_risk" do
    test "work lags elapsed calendar by more than the threshold -> :at_risk" do
      # window = 10 days; today (Jan 09) -> elapsed = 8/10 = 0.8.
      # work = 2/10 = 0.2; gap = 0.6 > 0.15 -> :at_risk. today is before target.
      t = target(~D[2026-01-01], ~D[2026-01-11])
      goals = [goal(2, 10, false)]

      assert Status.derive(t, goals, ~D[2026-01-09]) == :at_risk
    end

    test "mixed goals with children, work lags elapsed -> :at_risk" do
      # window = 10; today (Jan 10) -> elapsed = 9/10 = 0.9.
      # work = (10 + 0) / (10 + 10) = 0.5; gap = 0.4 > 0.15 -> :at_risk.
      t = target(~D[2026-01-01], ~D[2026-01-11])
      goals = [goal(10, 10, true), goal(0, 10, false)]

      assert Status.derive(t, goals, ~D[2026-01-10]) == :at_risk
    end
  end

  describe "derive/3 :on_track" do
    test "work keeps pace with elapsed calendar -> :on_track" do
      # window = 10; today (Jan 06) -> elapsed = 5/10 = 0.5.
      # work = 5/10 = 0.5; gap = 0.0 -> :on_track.
      t = target(~D[2026-01-01], ~D[2026-01-11])
      goals = [goal(5, 10, false)]

      assert Status.derive(t, goals, ~D[2026-01-06]) == :on_track
    end

    test "gap EXACTLY equal to the threshold -> :on_track (strict boundary)" do
      # window = diff(Apr 11, Jan 01) = 100 days; today (Mar 02) = created + 60
      # -> elapsed = 60/100 = 0.60. work = 45/100 = 0.45.
      # gap = 0.60 - 0.45 == exactly the 0.15 threshold, so NOT at_risk.
      #
      # Float note: 0.6 - 0.45 does NOT equal 0.15 in IEEE-754 — it lands one
      # ULP off (0.14999999999999997 or 0.15000000000000002 depending on the
      # platform). The module rounds the gap to 9 places before comparing, so
      # it ties the 0.15 threshold and is NOT strictly greater -> :on_track.
      t = target(~D[2026-01-01], ~D[2026-04-11])
      goals = [goal(45, 100, false)]

      assert 60 == Date.diff(~D[2026-03-02], ~D[2026-01-01])
      assert 100 == Date.diff(~D[2026-04-11], ~D[2026-01-01])
      # The raw subtraction carries last-bit noise (platform-dependent)...
      refute 0.6 - 0.45 == 0.15
      # ...which the module's 9-place rounding erases, tying the threshold.
      assert Float.round(0.6 - 0.45, 9) == 0.15

      assert Status.derive(t, goals, ~D[2026-03-02]) == :on_track
    end

    test "empty goal list -> :on_track (neutral, not vacuously complete)" do
      t = target(~D[2026-01-01], ~D[2026-01-11])

      assert Status.derive(t, [], ~D[2026-01-20]) == :on_track
    end

    test "zero-length creation->target window -> :on_track (div-by-zero guard)" do
      # created_on == target_date == today: window = 0. today is not past the
      # target (compare == :eq), goals incomplete, so the at_risk math is
      # skipped by the guard -> :on_track.
      t = target(~D[2026-05-01], ~D[2026-05-01])
      goals = [goal(0, 2, false)]

      assert Status.derive(t, goals, ~D[2026-05-01]) == :on_track
    end

    test "negative creation->target window -> :on_track (defensive guard)" do
      # Degenerate: target_date (May 01) precedes created_on (May 10); today
      # (Apr 25) is before the target so not missed, and window = -9 <= 0, so
      # the guard skips the division -> :on_track.
      t = target(~D[2026-05-10], ~D[2026-05-01])
      goals = [goal(0, 4, false)]

      assert Status.derive(t, goals, ~D[2026-04-25]) == :on_track
    end

    test "childless goals counted via goal_complete? fallback -> :on_track" do
      # window = 10; today (Jan 06) -> elapsed = 5/10 = 0.5.
      # Two childless goals: one complete (1/1), one not (0/1).
      # work = (1 + 0) / (1 + 1) = 0.5; gap = 0.0 -> :on_track.
      # Not all complete (one goal_complete? is false), so not :complete.
      t = target(~D[2026-01-01], ~D[2026-01-11])
      goals = [goal(0, 0, true), goal(0, 0, false)]

      assert Status.derive(t, goals, ~D[2026-01-06]) == :on_track
    end

    test "today before created_on clamps elapsed to 0.0 -> :on_track" do
      # created_on = Jun 01, target = Jun 30 (window = 29). today = May 15 is
      # before creation, so Date.diff(today, created_on) is negative and
      # elapsed_share clamps to 0.0. work = 0.0; gap = 0.0 -> :on_track.
      t = target(~D[2026-06-01], ~D[2026-06-30])
      goals = [goal(0, 5, false)]

      assert Status.derive(t, goals, ~D[2026-05-15]) == :on_track
    end
  end
end
