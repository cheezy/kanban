defmodule KanbanWeb.MetricsLive.HelpersTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.MetricsLive.Helpers

  describe "format_time/1" do
    test "formats Decimal seconds to minutes when less than 1 hour" do
      seconds = Decimal.new("1800")
      assert Helpers.format_time(seconds) == "30.0m"
    end

    test "formats Decimal seconds to hours when between 1 and 24 hours" do
      seconds = Decimal.new("7200")
      assert Helpers.format_time(seconds) == "2.0h"
    end

    test "formats Decimal seconds to days when >= 24 hours" do
      seconds = Decimal.new("172800")
      assert Helpers.format_time(seconds) == "2.0d"
    end

    test "formats number seconds to minutes when less than 1 hour" do
      assert Helpers.format_time(600) == "10.0m"
    end

    test "formats number seconds to hours when between 1 and 24 hours" do
      assert Helpers.format_time(3600) == "1.0h"
    end

    test "formats number seconds to days when >= 24 hours" do
      assert Helpers.format_time(86_400) == "1.0d"
    end

    test "returns N/A for nil" do
      assert Helpers.format_time(nil) == "N/A"
    end

    test "returns N/A for invalid input" do
      assert Helpers.format_time("invalid") == "N/A"
    end

    test "handles fractional values correctly" do
      assert Helpers.format_time(2100) == "35.0m"
      assert Helpers.format_time(5400) == "1.5h"
      assert Helpers.format_time(129_600) == "1.5d"
    end
  end

  describe "format_time_hours/1" do
    test "formats hours to minutes when less than 1 hour" do
      assert Helpers.format_time_hours(0.5) == "30.0m"
    end

    test "formats hours to hours when between 1 and 24 hours" do
      assert Helpers.format_time_hours(12.0) == "12.0h"
    end

    test "formats hours to days when >= 24 hours" do
      assert Helpers.format_time_hours(48.0) == "2.0d"
    end

    test "returns N/A for nil" do
      assert Helpers.format_time_hours(nil) == "N/A"
    end

    test "returns N/A for invalid input" do
      assert Helpers.format_time_hours("invalid") == "N/A"
    end
  end

  describe "format_datetime/1" do
    test "formats DateTime with proper format" do
      datetime = ~U[2024-03-15 14:30:00Z]
      assert Helpers.format_datetime(datetime) == "Mar 15, 2024 02:30 PM"
    end

    test "returns N/A for nil" do
      assert Helpers.format_datetime(nil) == "N/A"
    end
  end

  describe "format_date/1" do
    test "formats Date with proper format" do
      date = ~D[2024-03-15]
      assert Helpers.format_date(date) == "Mar 15, 2024"
    end

    test "returns N/A for nil" do
      assert Helpers.format_date(nil) == "N/A"
    end
  end

  describe "format_time_only/1" do
    test "formats DateTime to time only" do
      datetime = ~U[2024-03-15 14:30:00Z]
      assert Helpers.format_time_only(datetime) == "02:30 PM"
    end

    test "returns N/A for nil" do
      assert Helpers.format_time_only(nil) == "N/A"
    end
  end

  describe "get_start_date/1" do
    test "returns beginning of today for :today" do
      start_date = Helpers.get_start_date(:today)
      today = Date.utc_today()

      assert DateTime.to_date(start_date) == today
      assert start_date.hour == 0
      assert start_date.minute == 0
      assert start_date.second == 0
    end

    test "returns 7 days ago for :last_7_days" do
      start_date = Helpers.get_start_date(:last_7_days)
      expected = DateTime.add(DateTime.utc_now(), -7, :day)

      diff = DateTime.diff(expected, start_date, :second)
      assert abs(diff) < 2
    end

    test "returns 30 days ago for :last_30_days" do
      start_date = Helpers.get_start_date(:last_30_days)
      expected = DateTime.add(DateTime.utc_now(), -30, :day)

      diff = DateTime.diff(expected, start_date, :second)
      assert abs(diff) < 2
    end

    test "returns 90 days ago for :last_90_days" do
      start_date = Helpers.get_start_date(:last_90_days)
      expected = DateTime.add(DateTime.utc_now(), -90, :day)

      diff = DateTime.diff(expected, start_date, :second)
      assert abs(diff) < 2
    end

    test "returns fixed date for :all_time" do
      assert Helpers.get_start_date(:all_time) == ~U[2020-01-01 00:00:00Z]
    end

    test "returns 30 days ago for invalid input" do
      start_date = Helpers.get_start_date(:invalid)
      expected = DateTime.add(DateTime.utc_now(), -30, :day)

      diff = DateTime.diff(expected, start_date, :second)
      assert abs(diff) < 2
    end
  end

  describe "parse_time_range/1" do
    test "returns :last_30_days for nil" do
      assert Helpers.parse_time_range(nil) == :last_30_days
    end

    test "returns :last_30_days for empty string" do
      assert Helpers.parse_time_range("") == :last_30_days
    end

    test "converts valid string to atom" do
      assert Helpers.parse_time_range("last_7_days") == :last_7_days
      assert Helpers.parse_time_range("last_30_days") == :last_30_days
      assert Helpers.parse_time_range("last_90_days") == :last_90_days
      assert Helpers.parse_time_range("all_time") == :all_time
      assert Helpers.parse_time_range("today") == :today
    end

    test "returns :last_30_days for invalid string" do
      assert Helpers.parse_time_range("this_atom_definitely_does_not_exist_xyz_123") ==
               :last_30_days
    end
  end

  describe "parse_agent_name/1" do
    test "returns nil for nil input" do
      assert Helpers.parse_agent_name(nil) == nil
    end

    test "returns nil for empty string" do
      assert Helpers.parse_agent_name("") == nil
    end

    test "returns agent name for valid string" do
      assert Helpers.parse_agent_name("Claude Sonnet 4.5") == "Claude Sonnet 4.5"
    end
  end

  describe "parse_exclude_weekends/1" do
    test "returns false for nil" do
      assert Helpers.parse_exclude_weekends(nil) == false
    end

    test "returns false for empty string" do
      assert Helpers.parse_exclude_weekends("") == false
    end

    test "returns true for 'true' string" do
      assert Helpers.parse_exclude_weekends("true") == true
    end

    test "returns false for 'false' string" do
      assert Helpers.parse_exclude_weekends("false") == false
    end

    test "returns false for invalid input" do
      assert Helpers.parse_exclude_weekends("invalid") == false
      assert Helpers.parse_exclude_weekends("1") == false
      assert Helpers.parse_exclude_weekends("yes") == false
    end
  end

  describe "extract_time_seconds/1" do
    test "converts Decimal to float" do
      result =
        "3600.5"
        |> Decimal.new()
        |> Helpers.extract_time_seconds()

      assert result == 3600.5
    end

    test "returns number as-is" do
      assert Helpers.extract_time_seconds(1234.5) == 1234.5
      assert Helpers.extract_time_seconds(7200) == 7200
    end

    test "returns 0.0 for nil" do
      assert Helpers.extract_time_seconds(nil) == 0.0
    end

    test "returns 0.0 for invalid input" do
      assert Helpers.extract_time_seconds("invalid") == 0.0
    end
  end

  describe "calculate_average/1" do
    test "returns 0.0 for empty list" do
      assert Helpers.calculate_average([]) == 0.0
    end

    test "calculates average of values" do
      assert Helpers.calculate_average([10, 20, 30]) == 20.0
    end

    test "handles single value" do
      assert Helpers.calculate_average([42]) == 42.0
    end

    test "handles floats" do
      assert Helpers.calculate_average([1.5, 2.5, 3.0]) == 7.0 / 3
    end

    test "handles mixed integers and floats" do
      result = Helpers.calculate_average([1, 2.5, 3])
      assert_in_delta result, 2.1666666666, 0.0001
    end
  end

  describe "get_max_time/1" do
    test "returns 0 for empty list" do
      assert Helpers.get_max_time([]) == 0
    end

    test "returns max average_hours from daily times" do
      daily_times = [
        %{date: ~D[2024-01-01], average_hours: 2.5},
        %{date: ~D[2024-01-02], average_hours: 5.0},
        %{date: ~D[2024-01-03], average_hours: 3.2}
      ]

      assert Helpers.get_max_time(daily_times) == 5.0
    end

    test "handles single entry" do
      daily_times = [%{date: ~D[2024-01-01], average_hours: 4.2}]
      assert Helpers.get_max_time(daily_times) == 4.2
    end

    test "handles all zero values" do
      daily_times = [
        %{date: ~D[2024-01-01], average_hours: 0},
        %{date: ~D[2024-01-02], average_hours: 0}
      ]

      assert Helpers.get_max_time(daily_times) == 0
    end
  end

  describe "calculate_trend_line/1" do
    test "returns nil for empty list" do
      assert Helpers.calculate_trend_line([]) == nil
    end

    test "returns nil for single data point" do
      daily_times = [%{date: ~D[2024-01-01], average_hours: 5.0}]
      assert Helpers.calculate_trend_line(daily_times) == nil
    end

    test "calculates trend line for two points" do
      daily_times = [
        %{date: ~D[2024-01-01], average_hours: 2.0},
        %{date: ~D[2024-01-02], average_hours: 4.0}
      ]

      result = Helpers.calculate_trend_line(daily_times)
      assert result != nil
      assert Map.has_key?(result, :slope)
      assert Map.has_key?(result, :intercept)
      assert result.slope == 2.0
      assert result.intercept == 2.0
    end

    test "calculates trend line for upward trend" do
      daily_times = [
        %{date: ~D[2024-01-01], average_hours: 1.0},
        %{date: ~D[2024-01-02], average_hours: 2.0},
        %{date: ~D[2024-01-03], average_hours: 3.0},
        %{date: ~D[2024-01-04], average_hours: 4.0}
      ]

      result = Helpers.calculate_trend_line(daily_times)
      assert result != nil
      assert result.slope > 0
    end

    test "calculates trend line for downward trend" do
      daily_times = [
        %{date: ~D[2024-01-01], average_hours: 4.0},
        %{date: ~D[2024-01-02], average_hours: 3.0},
        %{date: ~D[2024-01-03], average_hours: 2.0},
        %{date: ~D[2024-01-04], average_hours: 1.0}
      ]

      result = Helpers.calculate_trend_line(daily_times)
      assert result != nil
      assert result.slope < 0
    end

    test "calculates trend line for flat trend" do
      daily_times = [
        %{date: ~D[2024-01-01], average_hours: 3.0},
        %{date: ~D[2024-01-02], average_hours: 3.0},
        %{date: ~D[2024-01-03], average_hours: 3.0}
      ]

      result = Helpers.calculate_trend_line(daily_times)
      assert result != nil
      assert_in_delta result.slope, 0.0, 0.0001
      assert_in_delta result.intercept, 3.0, 0.0001
    end
  end

  describe "group_tasks_by_completion_date/1" do
    test "groups tasks by completion date" do
      tasks = [
        %{id: 1, completed_at: ~U[2024-01-01 10:00:00Z], title: "Task 1"},
        %{id: 2, completed_at: ~U[2024-01-01 14:00:00Z], title: "Task 2"},
        %{id: 3, completed_at: ~U[2024-01-02 09:00:00Z], title: "Task 3"}
      ]

      result = Helpers.group_tasks_by_completion_date(tasks)

      assert length(result) == 2
      assert [{date1, tasks1}, {date2, tasks2}] = result

      assert date1 == ~D[2024-01-02]
      assert length(tasks1) == 1
      assert hd(tasks1).id == 3

      assert date2 == ~D[2024-01-01]
      assert length(tasks2) == 2
    end

    test "sorts dates in descending order" do
      tasks = [
        %{id: 1, completed_at: ~U[2024-01-01 10:00:00Z], title: "Task 1"},
        %{id: 2, completed_at: ~U[2024-01-03 10:00:00Z], title: "Task 2"},
        %{id: 3, completed_at: ~U[2024-01-02 10:00:00Z], title: "Task 3"}
      ]

      result = Helpers.group_tasks_by_completion_date(tasks)

      dates = Enum.map(result, fn {date, _tasks} -> date end)
      assert dates == [~D[2024-01-03], ~D[2024-01-02], ~D[2024-01-01]]
    end

    test "sorts tasks within each day by completed_at descending" do
      tasks = [
        %{id: 1, completed_at: ~U[2024-01-01 08:00:00Z], title: "Task 1"},
        %{id: 2, completed_at: ~U[2024-01-01 14:00:00Z], title: "Task 2"},
        %{id: 3, completed_at: ~U[2024-01-01 10:00:00Z], title: "Task 3"}
      ]

      result = Helpers.group_tasks_by_completion_date(tasks)

      assert [{_date, day_tasks}] = result
      assert Enum.map(day_tasks, & &1.id) == [2, 3, 1]
    end

    test "handles empty list" do
      assert Helpers.group_tasks_by_completion_date([]) == []
    end
  end

  describe "calculate_daily_times/2" do
    test "calculates daily averages for cycle_time_seconds" do
      tasks = [
        %{completed_at: ~U[2024-01-01 10:00:00Z], cycle_time_seconds: 3600},
        %{completed_at: ~U[2024-01-01 14:00:00Z], cycle_time_seconds: 7200},
        %{completed_at: ~U[2024-01-02 09:00:00Z], cycle_time_seconds: 1800}
      ]

      result = Helpers.calculate_daily_times(tasks, :cycle_time_seconds)

      assert length(result) == 2

      jan1 = Enum.find(result, fn day -> day.date == ~D[2024-01-01] end)
      assert jan1 != nil
      assert_in_delta jan1.average_hours, 1.5, 0.001

      jan2 = Enum.find(result, fn day -> day.date == ~D[2024-01-02] end)
      assert jan2 != nil
      assert_in_delta jan2.average_hours, 0.5, 0.001
    end

    test "calculates daily averages for lead_time_seconds" do
      tasks = [
        %{completed_at: ~U[2024-01-01 10:00:00Z], lead_time_seconds: 86_400},
        %{completed_at: ~U[2024-01-01 14:00:00Z], lead_time_seconds: 43_200}
      ]

      result = Helpers.calculate_daily_times(tasks, :lead_time_seconds)

      assert length(result) == 1
      day = hd(result)
      assert day.date == ~D[2024-01-01]
      assert_in_delta day.average_hours, 18.0, 0.001
    end

    test "sorts results by date ascending" do
      tasks = [
        %{completed_at: ~U[2024-01-03 10:00:00Z], cycle_time_seconds: 3600},
        %{completed_at: ~U[2024-01-01 10:00:00Z], cycle_time_seconds: 3600},
        %{completed_at: ~U[2024-01-02 10:00:00Z], cycle_time_seconds: 3600}
      ]

      result = Helpers.calculate_daily_times(tasks, :cycle_time_seconds)

      dates = Enum.map(result, & &1.date)
      assert dates == [~D[2024-01-01], ~D[2024-01-02], ~D[2024-01-03]]
    end

    test "handles Decimal values" do
      tasks = [
        %{completed_at: ~U[2024-01-01 10:00:00Z], cycle_time_seconds: Decimal.new("3600")}
      ]

      result = Helpers.calculate_daily_times(tasks, :cycle_time_seconds)

      assert length(result) == 1
      day = hd(result)
      assert_in_delta day.average_hours, 1.0, 0.001
    end

    test "handles empty list" do
      assert Helpers.calculate_daily_times([], :cycle_time_seconds) == []
    end

    test "handles mixed numeric types" do
      tasks = [
        %{completed_at: ~U[2024-01-01 10:00:00Z], cycle_time_seconds: 3600},
        %{completed_at: ~U[2024-01-01 14:00:00Z], cycle_time_seconds: 3600.0},
        %{completed_at: ~U[2024-01-01 16:00:00Z], cycle_time_seconds: Decimal.new("3600")}
      ]

      result = Helpers.calculate_daily_times(tasks, :cycle_time_seconds)

      assert length(result) == 1
      day = hd(result)
      assert_in_delta day.average_hours, 1.0, 0.001
    end
  end
end
