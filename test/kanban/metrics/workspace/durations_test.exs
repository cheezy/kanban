defmodule Kanban.Metrics.Workspace.DurationsTest do
  use ExUnit.Case, async: true

  alias Kanban.Metrics.Workspace.Durations

  # Fri 2026-01-30 18:00 UTC -> Mon 2026-02-02 10:00 UTC is 64h wall-clock and
  # 16h of business time (the whole of Sat + Sun falls inside it). These are
  # plain data structs, so fixed literals are safe here — unlike the workspace
  # context tests, nothing filters them by a trailing window.
  @friday_evening ~U[2026-01-30 18:00:00Z]
  @monday_morning ~U[2026-02-02 10:00:00Z]

  describe "cycle_minutes/2" do
    test "returns the full wall-clock span when weekends are included" do
      task = %{claimed_at: @friday_evening, completed_at: @monday_morning}

      assert Durations.cycle_minutes(task, false) == 64 * 60
    end

    test "subtracts the weekend portion when weekends are excluded" do
      task = %{claimed_at: @friday_evening, completed_at: @monday_morning}

      assert Durations.cycle_minutes(task, true) == 16 * 60
    end

    test "leaves a span that never touches a weekend unchanged" do
      task = %{
        claimed_at: ~U[2026-02-03 09:00:00Z],
        completed_at: ~U[2026-02-04 09:00:00Z]
      }

      assert Durations.cycle_minutes(task, true) == 24 * 60
      assert Durations.cycle_minutes(task, false) == 24 * 60
    end

    test "clamps a span falling entirely inside a weekend to zero" do
      task = %{
        claimed_at: ~U[2026-01-31 09:00:00Z],
        completed_at: ~U[2026-02-01 17:00:00Z]
      }

      assert Durations.cycle_minutes(task, true) == 0
    end

    test "returns nil when the task was never claimed" do
      assert Durations.cycle_minutes(%{claimed_at: nil, completed_at: @monday_morning}, true) ==
               nil

      assert Durations.cycle_minutes(%{claimed_at: @friday_evening, completed_at: nil}, false) ==
               nil
    end
  end

  describe "lead_minutes/2" do
    test "measures from the NaiveDateTime inserted_at, honouring the weekend flag" do
      task = %{
        inserted_at: ~N[2026-01-30 18:00:00],
        completed_at: @monday_morning
      }

      assert Durations.lead_minutes(task, false) == 64 * 60
      assert Durations.lead_minutes(task, true) == 16 * 60
    end

    test "returns nil when the task is not complete" do
      assert Durations.lead_minutes(
               %{inserted_at: ~N[2026-01-30 18:00:00], completed_at: nil},
               true
             ) ==
               nil
    end
  end

  describe "review_wait_minutes/2" do
    test "measures completion to review, honouring the weekend flag" do
      task = %{
        needs_review: true,
        completed_at: @friday_evening,
        reviewed_at: @monday_morning
      }

      assert Durations.review_wait_minutes(task, false) == 64 * 60
      assert Durations.review_wait_minutes(task, true) == 16 * 60
    end

    test "returns nil when the task did not need review or was never reviewed" do
      base = %{needs_review: true, completed_at: @friday_evening, reviewed_at: @monday_morning}

      assert Durations.review_wait_minutes(%{base | needs_review: false}, true) == nil

      assert Durations.review_wait_minutes(
               %{needs_review: true, completed_at: @friday_evening, reviewed_at: nil},
               true
             ) == nil
    end
  end

  describe "roll-ups" do
    test "median_cycle_minutes/2 rejects tasks with no cycle time" do
      tasks = [
        %{claimed_at: ~U[2026-02-03 09:00:00Z], completed_at: ~U[2026-02-03 10:00:00Z]},
        %{claimed_at: ~U[2026-02-03 09:00:00Z], completed_at: ~U[2026-02-03 12:00:00Z]},
        %{claimed_at: nil, completed_at: ~U[2026-02-03 12:00:00Z]}
      ]

      # Median of [60, 180] — the unclaimed task is excluded, not counted as 0.
      assert Durations.median_cycle_minutes(tasks, false) == 120
    end

    test "the roll-ups return 0 for an empty list rather than raising" do
      assert Durations.median_cycle_minutes([], true) == 0
      assert Durations.median_lead_minutes([], true) == 0
      assert Durations.median_review_wait_minutes([], true) == 0
      assert Durations.percentile_lead_minutes([], 90, true) == 0
    end

    test "median_lead_minutes/2 is the p50 of percentile_lead_minutes/3" do
      tasks =
        for hours <- [1, 2, 3, 10] do
          %{
            inserted_at: ~N[2026-02-03 00:00:00],
            completed_at: DateTime.add(~U[2026-02-03 00:00:00Z], hours * 3600, :second)
          }
        end

      assert Durations.median_lead_minutes(tasks, false) ==
               Durations.percentile_lead_minutes(tasks, 50, false)
    end
  end
end
