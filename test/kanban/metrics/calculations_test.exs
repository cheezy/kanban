defmodule Kanban.Metrics.CalculationsTest do
  use ExUnit.Case, async: true

  alias Kanban.Metrics.Calculations

  doctest Kanban.Metrics.Calculations

  describe "average/1" do
    test "calculates average of multiple numbers" do
      assert Calculations.average([10, 20, 30]) == 20.0
      assert Calculations.average([1, 2, 3, 4, 5]) == 3.0
    end

    test "handles single element" do
      assert Calculations.average([42]) == 42.0
    end

    test "handles floats" do
      assert_in_delta Calculations.average([1.5, 2.5, 3.0]), 2.333, 0.001
    end

    test "returns nil for empty list" do
      assert Calculations.average([]) == nil
    end
  end

  describe "median/1" do
    test "calculates median for odd-length list" do
      assert Calculations.median([10, 20, 30]) == 20
      assert Calculations.median([1, 5, 3, 7, 9]) == 5
    end

    test "calculates median for even-length list" do
      assert Calculations.median([10, 20, 30, 40]) == 25.0
      assert Calculations.median([1, 2, 3, 4]) == 2.5
    end

    test "handles single element" do
      assert Calculations.median([42]) == 42
    end

    test "handles unsorted lists" do
      assert Calculations.median([30, 10, 20]) == 20
      assert Calculations.median([40, 10, 30, 20]) == 25.0
    end

    test "returns nil for empty list" do
      assert Calculations.median([]) == nil
    end
  end

  describe "percentile/2" do
    test "calculates 50th percentile (median)" do
      assert Calculations.percentile([10, 20, 30, 40, 50], 50) == 30
    end

    test "calculates 90th percentile" do
      result = Calculations.percentile([10, 20, 30, 40, 50], 90)
      assert_in_delta result, 46.0, 0.1
    end

    test "calculates 95th percentile" do
      result = Calculations.percentile([10, 20, 30, 40, 50], 95)
      assert_in_delta result, 48.0, 0.1
    end

    test "handles 0th percentile (minimum)" do
      assert Calculations.percentile([10, 20, 30, 40, 50], 0) == 10
    end

    test "handles 100th percentile (maximum)" do
      assert Calculations.percentile([10, 20, 30, 40, 50], 100) == 50
    end

    test "handles single element" do
      assert Calculations.percentile([42], 50) == 42
      assert Calculations.percentile([42], 90) == 42
    end

    test "returns nil for empty list" do
      assert Calculations.percentile([], 50) == nil
    end
  end

  describe "exclude_weekends/1" do
    test "filters out Saturday and Sunday" do
      dates = [
        ~D[2026-01-31],
        ~D[2026-02-01],
        ~D[2026-02-02],
        ~D[2026-02-03],
        ~D[2026-02-04]
      ]

      result = Calculations.exclude_weekends(dates)

      assert result == [~D[2026-02-02], ~D[2026-02-03], ~D[2026-02-04]]
    end

    test "returns all dates when no weekends present" do
      dates = [~D[2026-02-02], ~D[2026-02-03], ~D[2026-02-04]]

      result = Calculations.exclude_weekends(dates)

      assert result == dates
    end

    test "returns empty list when only weekends" do
      dates = [~D[2026-01-31], ~D[2026-02-01]]

      result = Calculations.exclude_weekends(dates)

      assert result == []
    end

    test "handles empty list" do
      assert Calculations.exclude_weekends([]) == []
    end
  end

  describe "business_hours_between/3" do
    test "calculates hours without weekend exclusion" do
      start_time = ~U[2026-02-02 09:00:00Z]
      end_time = ~U[2026-02-02 17:00:00Z]

      result = Calculations.business_hours_between(start_time, end_time, false)

      assert result == 8.0
    end

    test "calculates hours with weekend exclusion" do
      start_time = ~U[2026-01-31 10:00:00Z]
      end_time = ~U[2026-02-03 10:00:00Z]

      result = Calculations.business_hours_between(start_time, end_time, true)

      assert result == 24.0
    end

    test "handles same day calculation" do
      start_time = ~U[2026-02-02 09:00:00Z]
      end_time = ~U[2026-02-02 17:00:00Z]

      result = Calculations.business_hours_between(start_time, end_time, true)

      assert result == 8.0
    end

    test "handles multi-day weekday period" do
      start_time = ~U[2026-02-02 09:00:00Z]
      end_time = ~U[2026-02-04 17:00:00Z]

      result = Calculations.business_hours_between(start_time, end_time, false)

      assert result == 56.0
    end

    test "returns zero when start equals end" do
      time = ~U[2026-02-02 09:00:00Z]

      result = Calculations.business_hours_between(time, time, false)

      assert result == 0.0
    end
  end

  describe "group_by_period/2" do
    test "groups by day (no aggregation)" do
      data = [{~D[2026-02-01], 5}, {~D[2026-02-02], 3}]

      result = Calculations.group_by_period(data, :day)

      assert result == data
    end

    test "groups by week" do
      data = [
        {~D[2026-02-02], 5},
        {~D[2026-02-03], 3},
        {~D[2026-02-09], 7}
      ]

      result = Calculations.group_by_period(data, :week)

      assert result == [
               {~D[2026-02-02], 8},
               {~D[2026-02-09], 7}
             ]
    end

    test "groups by month" do
      data = [
        {~D[2026-02-02], 5},
        {~D[2026-02-15], 3},
        {~D[2026-03-01], 7}
      ]

      result = Calculations.group_by_period(data, :month)

      assert result == [
               {~D[2026-02-01], 8},
               {~D[2026-03-01], 7}
             ]
    end

    test "handles empty list" do
      assert Calculations.group_by_period([], :day) == []
      assert Calculations.group_by_period([], :week) == []
      assert Calculations.group_by_period([], :month) == []
    end

    test "handles single entry" do
      data = [{~D[2026-02-02], 5}]

      assert Calculations.group_by_period(data, :week) == [{~D[2026-02-02], 5}]
      assert Calculations.group_by_period(data, :month) == [{~D[2026-02-01], 5}]
    end
  end
end
