defmodule Kanban.Metrics.Calculations do
  @moduledoc """
  Pure functions for statistical calculations and time-based computations.

  This module provides reusable calculation functions for metrics aggregation,
  including averages, medians, percentiles, and business time calculations.
  All functions are pure (no side effects) and handle edge cases gracefully.
  """

  @doc """
  Calculates the average of a list of numbers.

  Returns `nil` for empty lists.

  ## Examples

      iex> Kanban.Metrics.Calculations.average([10, 20, 30])
      20.0

      iex> Kanban.Metrics.Calculations.average([])
      nil

  """
  @spec average([number()]) :: float() | nil
  def average([]), do: nil

  def average(numbers) when is_list(numbers) do
    Enum.sum(numbers) / length(numbers)
  end

  @doc """
  Calculates the median of a sorted or unsorted list of numbers.

  Returns `nil` for empty lists. For lists with an even number of elements,
  returns the average of the two middle values.

  ## Examples

      iex> Kanban.Metrics.Calculations.median([10, 20, 30])
      20

      iex> Kanban.Metrics.Calculations.median([10, 20, 30, 40])
      25.0

      iex> Kanban.Metrics.Calculations.median([])
      nil

  """
  @spec median([number()]) :: number() | nil
  def median([]), do: nil

  def median(numbers) when is_list(numbers) do
    sorted = Enum.sort(numbers)
    count = length(sorted)
    middle = div(count, 2)

    if rem(count, 2) == 0 do
      (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2
    else
      Enum.at(sorted, middle)
    end
  end

  @doc """
  Calculates the nth percentile of a list of numbers.

  The percentile should be between 0 and 100. Returns `nil` for empty lists.

  ## Examples

      iex> Kanban.Metrics.Calculations.percentile([10, 20, 30, 40, 50], 50)
      30

      iex> Kanban.Metrics.Calculations.percentile([10, 20, 30, 40, 50], 90)
      46.0

      iex> Kanban.Metrics.Calculations.percentile([], 50)
      nil

  """
  @spec percentile([number()], number()) :: number() | nil
  def percentile([], _n), do: nil

  def percentile(numbers, n) when is_list(numbers) and n >= 0 and n <= 100 do
    sorted = Enum.sort(numbers)
    count = length(sorted)
    rank = n / 100 * (count - 1)
    lower_index = floor(rank)
    upper_index = ceil(rank)

    if lower_index == upper_index do
      Enum.at(sorted, lower_index)
    else
      lower_value = Enum.at(sorted, lower_index)
      upper_value = Enum.at(sorted, upper_index)
      lower_value + (upper_value - lower_value) * (rank - lower_index)
    end
  end

  @doc """
  Filters a list of dates to exclude weekends (Saturday and Sunday).

  ## Examples

      iex> dates = [~D[2026-02-02], ~D[2026-02-03], ~D[2026-02-04]]
      iex> Kanban.Metrics.Calculations.exclude_weekends(dates)
      [~D[2026-02-02], ~D[2026-02-03], ~D[2026-02-04]]

  """
  @spec exclude_weekends([Date.t()]) :: [Date.t()]
  def exclude_weekends(dates) when is_list(dates) do
    Enum.reject(dates, fn date ->
      Date.day_of_week(date) in [6, 7]
    end)
  end

  @doc """
  Calculates the number of business hours between two DateTimes, excluding weekends.

  Weekends are defined as Saturday (6) and Sunday (7). The function calculates
  the total time difference and subtracts full weekend days.

  ## Examples

      iex> start_time = ~U[2026-02-02 09:00:00Z]
      iex> end_time = ~U[2026-02-04 17:00:00Z]
      iex> Kanban.Metrics.Calculations.business_hours_between(start_time, end_time, true)
      56.0

  """
  @spec business_hours_between(DateTime.t(), DateTime.t(), boolean()) :: float()
  def business_hours_between(start_time, end_time, exclude_weekends \\ false)

  def business_hours_between(start_time, end_time, false) do
    DateTime.diff(end_time, start_time, :second) / 3600
  end

  def business_hours_between(start_time, end_time, true) do
    start_date = DateTime.to_date(start_time)
    end_date = DateTime.to_date(end_time)

    total_seconds = DateTime.diff(end_time, start_time, :second)

    weekend_days =
      Date.range(start_date, end_date)
      |> Enum.count(fn date -> Date.day_of_week(date) in [6, 7] end)

    business_seconds = max(total_seconds - weekend_days * 86_400, 0)
    business_seconds / 3600
  end

  @doc """
  Groups a list of {date, value} tuples by time period.

  Supported periods: `:day`, `:week`, `:month`.

  ## Examples

      iex> data = [{~D[2026-02-01], 5}, {~D[2026-02-02], 3}]
      iex> Kanban.Metrics.Calculations.group_by_period(data, :day)
      [{~D[2026-02-01], 5}, {~D[2026-02-02], 3}]

  """
  @spec group_by_period([{Date.t(), number()}], :day | :week | :month) :: [
          {Date.t(), number()}
        ]
  def group_by_period(data, :day), do: data

  def group_by_period(data, :week) do
    data
    |> Enum.group_by(fn {date, _value} ->
      Date.beginning_of_week(date)
    end)
    |> Enum.map(fn {week_start, entries} ->
      total =
        entries
        |> Enum.map(fn {_date, value} -> value end)
        |> Enum.sum()

      {week_start, total}
    end)
    |> Enum.sort_by(fn {date, _value} -> date end)
  end

  def group_by_period(data, :month) do
    data
    |> Enum.group_by(fn {date, _value} ->
      Date.beginning_of_month(date)
    end)
    |> Enum.map(fn {month_start, entries} ->
      total =
        entries
        |> Enum.map(fn {_date, value} -> value end)
        |> Enum.sum()

      {month_start, total}
    end)
    |> Enum.sort_by(fn {date, _value} -> date end)
  end
end
