defmodule Kanban.Metrics.Workspace.WindowsTest do
  use ExUnit.Case, async: true

  alias Kanban.Metrics.Workspace.Windows

  @tz "Etc/UTC"

  describe "day_range/3" do
    test "returns window_days consecutive days ending today by default" do
      days = Windows.day_range(14, @tz)

      assert length(days) == 14
      assert List.last(days) == Date.utc_today()
      assert List.first(days) == Date.add(Date.utc_today(), -13)
    end

    test "the weekend flag defaults to false, so arity 2 is unchanged" do
      assert Windows.day_range(14, @tz) == Windows.day_range(14, @tz, false)
    end

    test "drops Saturdays and Sundays when weekends are excluded" do
      days = Windows.day_range(14, @tz, true)

      assert Enum.all?(days, &(Date.day_of_week(&1) not in [6, 7]))
    end

    test "a 14-day window always keeps exactly 10 weekdays, a 7-day window exactly 5" do
      # Two calendar weeks contain exactly 4 weekend days no matter which day
      # they start on, so these counts hold whenever the suite runs.
      assert length(Windows.day_range(14, @tz, true)) == 10
      assert length(Windows.day_range(7, @tz, true)) == 5
    end

    test "shortens the list rather than reaching further back" do
      excluded = Windows.day_range(14, @tz, true)
      included = Windows.day_range(14, @tz, false)

      oldest_excluded = Enum.min(excluded, Date)
      oldest_included = Enum.min(included, Date)
      newest_excluded = List.last(excluded)

      # The window still spans the same calendar days: the oldest retained day
      # is never older than the oldest day of the unfiltered window.
      assert Date.compare(oldest_excluded, oldest_included) in [:gt, :eq]
      assert Date.day_of_week(newest_excluded) not in [6, 7]
    end

    test "stays ordered oldest-to-newest after filtering" do
      days = Windows.day_range(30, @tz, true)

      assert days == Enum.sort(days, Date)
    end
  end

  describe "previous_day_range/3" do
    test "is the equal-length window immediately before day_range/3" do
      current = Windows.day_range(14, @tz)
      previous = Windows.previous_day_range(14, @tz)

      newest_previous = List.last(previous)

      assert length(previous) == 14
      assert Date.add(newest_previous, 1) == List.first(current)
    end

    test "drops weekends when asked, and can differ in length from the current window" do
      previous = Windows.previous_day_range(30, @tz, true)

      assert Enum.all?(previous, &(Date.day_of_week(&1) not in [6, 7]))

      # A 30-day window holds 20-22 weekdays depending on where it starts, which
      # is exactly why the KPI denominators are counted per window rather than
      # shared. (14-day windows always hold 10, so they cannot show this.)
      assert length(previous) in 20..22
    end

    test "a 14-day previous window always holds exactly 10 weekdays" do
      assert length(Windows.previous_day_range(14, @tz, true)) == 10
      assert length(Windows.previous_day_range(7, @tz, true)) == 5
    end

    test "the weekend flag defaults to false" do
      assert Windows.previous_day_range(14, @tz) == Windows.previous_day_range(14, @tz, false)
    end
  end
end
