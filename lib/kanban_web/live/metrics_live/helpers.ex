defmodule KanbanWeb.MetricsLive.Helpers do
  @moduledoc """
  Shared helper functions for metrics LiveView modules.
  Provides common formatting, parsing, and calculation utilities.
  """

  def format_time(%Decimal{} = seconds) do
    seconds
    |> Decimal.to_float()
    |> format_time()
  end

  def format_time(seconds) when is_number(seconds) do
    hours = seconds / 3600

    cond do
      hours < 1 -> "#{Float.round(hours * 60, 1)}m"
      hours < 24 -> "#{Float.round(hours, 1)}h"
      true -> "#{Float.round(hours / 24, 1)}d"
    end
  end

  def format_time(_), do: "N/A"

  def format_time_hours(hours) when is_number(hours) do
    cond do
      hours < 1 -> "#{Float.round(hours * 60, 1)}m"
      hours < 24 -> "#{Float.round(hours, 1)}h"
      true -> "#{Float.round(hours / 24, 1)}d"
    end
  end

  def format_time_hours(_), do: "N/A"

  def format_datetime(nil), do: "N/A"

  def format_datetime(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y %I:%M %p")
  end

  def format_date(nil), do: "N/A"

  def format_date(date) do
    Calendar.strftime(date, "%b %d, %Y")
  end

  def format_time_only(nil), do: "N/A"

  def format_time_only(datetime) do
    Calendar.strftime(datetime, "%I:%M %p")
  end

  def get_start_date(:today) do
    DateTime.utc_now()
    |> DateTime.to_date()
    |> DateTime.new!(~T[00:00:00])
  end

  def get_start_date(:last_7_days), do: DateTime.add(DateTime.utc_now(), -7, :day)
  def get_start_date(:last_30_days), do: DateTime.add(DateTime.utc_now(), -30, :day)
  def get_start_date(:last_90_days), do: DateTime.add(DateTime.utc_now(), -90, :day)
  def get_start_date(:all_time), do: ~U[2020-01-01 00:00:00Z]
  def get_start_date(_), do: DateTime.add(DateTime.utc_now(), -30, :day)

  def parse_time_range(nil), do: :last_30_days
  def parse_time_range(""), do: :last_30_days

  def parse_time_range(time_range) when is_binary(time_range) do
    String.to_existing_atom(time_range)
  rescue
    ArgumentError -> :last_30_days
  end

  def parse_agent_name(nil), do: nil
  def parse_agent_name(""), do: nil
  def parse_agent_name(agent_name) when is_binary(agent_name), do: agent_name

  def parse_exclude_weekends(nil), do: false
  def parse_exclude_weekends(""), do: false
  def parse_exclude_weekends("true"), do: true
  def parse_exclude_weekends("false"), do: false
  def parse_exclude_weekends(_), do: false

  def extract_time_seconds(%Decimal{} = seconds), do: Decimal.to_float(seconds)
  def extract_time_seconds(seconds) when is_number(seconds), do: seconds
  def extract_time_seconds(_), do: 0.0

  def calculate_average([]), do: 0.0
  def calculate_average(values), do: Enum.sum(values) / length(values)

  def get_max_time([]), do: 0

  def get_max_time(daily_times) do
    daily_times
    |> Enum.map(& &1.average_hours)
    |> Enum.max(fn -> 0 end)
  end

  def calculate_trend_line([]), do: nil
  def calculate_trend_line([_single]), do: nil

  def calculate_trend_line(daily_times) do
    n = length(daily_times)
    {sum_x, sum_y, sum_xy, sum_x_squared} = calculate_regression_sums(daily_times)

    slope = calculate_slope(n, sum_x, sum_y, sum_xy, sum_x_squared)
    intercept = calculate_intercept(n, sum_x, sum_y, slope)

    %{slope: slope, intercept: intercept}
  end

  defp calculate_regression_sums(daily_times) do
    daily_times
    |> Enum.with_index()
    |> Enum.reduce({0.0, 0.0, 0.0, 0.0}, fn {day, index}, {sx, sy, sxy, sx2} ->
      x = index * 1.0
      y = day.average_hours
      {sx + x, sy + y, sxy + x * y, sx2 + x * x}
    end)
  end

  defp calculate_slope(n, sum_x, sum_y, sum_xy, sum_x_squared) do
    (n * sum_xy - sum_x * sum_y) / (n * sum_x_squared - sum_x * sum_x)
  end

  defp calculate_intercept(n, sum_x, sum_y, slope) do
    (sum_y - slope * sum_x) / n
  end

  def group_tasks_by_completion_date(tasks) do
    tasks
    |> Enum.group_by(fn task ->
      task.completed_at
      |> DateTime.to_date()
    end)
    |> Enum.sort_by(fn {date, _tasks} -> date end, {:desc, Date})
    |> Enum.map(fn {date, day_tasks} ->
      {date, Enum.sort_by(day_tasks, & &1.completed_at, {:desc, DateTime})}
    end)
  end

  def calculate_daily_times(tasks, time_field) do
    tasks
    |> Enum.group_by(fn task ->
      task.completed_at |> DateTime.to_date()
    end)
    |> Enum.map(fn {date, day_tasks} ->
      times = Enum.map(day_tasks, &extract_time_seconds(Map.get(&1, time_field)))
      average_seconds = calculate_average(times)

      %{
        date: date,
        average_hours: average_seconds / 3600
      }
    end)
    |> Enum.sort_by(& &1.date, Date)
  end
end
