defmodule KanbanWeb.GoalLive.SidebarVelocityTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.GoalLive.SidebarVelocity

  @now ~U[2026-11-16 12:00:00Z]

  defp ago(seconds), do: DateTime.add(@now, -seconds, :second)

  defp count_for(age_seconds, unit),
    do: age_seconds |> ago() |> SidebarVelocity.bucket_count(unit, @now)

  describe "bucket_count/3" do
    test "uses the full 12 buckets when there is no signal at all" do
      assert SidebarVelocity.bucket_count(nil, :hour, @now) == 12
    end

    test "never drops below 2 buckets" do
      assert SidebarVelocity.bucket_count(@now, :hour, @now) == 2
      assert count_for(3599, :hour) == 2
    end

    test "gives a future earliest signal the 2-bucket minimum" do
      assert count_for(-7200, :hour) == 2
    end

    test "gives one hourly bucket per elapsed hour plus the current one" do
      assert count_for(3 * 3600, :hour) == 4
      assert count_for(10 * 3600 + 59, :hour) == 11
    end

    test "caps hourly buckets at 12, including at exactly 24 hours" do
      assert count_for(11 * 3600, :hour) == 12
      assert count_for(86_400, :hour) == 12
    end

    test "gives one daily bucket per elapsed day plus the current one" do
      assert count_for(86_401, :day) == 2
      assert count_for(2 * 86_400, :day) == 3
      assert count_for(10 * 86_400, :day) == 11
    end

    test "caps daily buckets at 12" do
      assert count_for(11 * 86_400, :day) == 12
      assert count_for(12 * 86_400, :day) == 12
      assert count_for(400 * 86_400, :day) == 12
    end
  end

  describe "build/3" do
    test "sizes a 2-day-old goal to 3 daily buckets, oldest first" do
      goal = %{inserted_at: (2 * 86_400 + 60) |> ago() |> DateTime.to_naive(), claimed_at: nil}

      children = [
        %{completed_at: ago(2 * 86_400)},
        %{completed_at: ago(60)},
        %{completed_at: ago(120)},
        %{completed_at: nil}
      ]

      result = SidebarVelocity.build(goal, children, @now)

      assert result.sparkline_unit == :day
      assert result.sparkline_count == 3
      assert result.sparkline_data == [1, 0, 2]
    end

    test "starts the caption at the first bucket's period" do
      goal = %{inserted_at: ago(2 * 86_400 + 60), claimed_at: nil}

      assert SidebarVelocity.build(goal, [], @now).sparkline_label ==
               "Nov 13, 2026 — Nov 16, 2026"

      young = %{inserted_at: ago(3 * 3600 + 60), claimed_at: nil}
      result = SidebarVelocity.build(young, [], @now)

      assert result.sparkline_unit == :hour
      assert result.sparkline_count == 4
      assert result.sparkline_data == [0, 0, 0, 0]
      assert result.sparkline_label =~ ~r/^8:00\s?AM — 12:00\s?PM$/
    end

    test "keeps the hourly unit at exactly 24 hours and switches to days 1s later" do
      at_24h = SidebarVelocity.build(%{inserted_at: ago(86_400), claimed_at: nil}, [], @now)

      assert at_24h.sparkline_unit == :hour
      assert at_24h.sparkline_count == 12

      past_24h = SidebarVelocity.build(%{inserted_at: ago(86_401), claimed_at: nil}, [], @now)

      assert past_24h.sparkline_unit == :day
      assert past_24h.sparkline_count == 2
      assert length(past_24h.sparkline_data) == 2
    end

    test "uses the claim when it is older than the insert" do
      goal = %{inserted_at: ago(60), claimed_at: ago(5 * 86_400)}

      result = SidebarVelocity.build(goal, [], @now)

      assert result.sparkline_count == 6
      assert length(result.sparkline_data) == 6
    end

    test "keeps 12 buckets for an old goal and drops completions outside them" do
      goal = %{inserted_at: ago(30 * 86_400), claimed_at: nil}
      children = [%{completed_at: ago(20 * 86_400)}, %{completed_at: ago(3600)}]

      result = SidebarVelocity.build(goal, children, @now)

      assert result.sparkline_count == 12
      assert result.sparkline_data == List.duplicate(0, 11) ++ [1]
    end

    test "falls back to 12 hourly buckets when the goal carries no timestamps" do
      result = SidebarVelocity.build(%{}, [], @now)

      assert result.sparkline_unit == :hour
      assert result.sparkline_count == 12
      assert result.sparkline_data == List.duplicate(0, 12)
    end
  end
end
