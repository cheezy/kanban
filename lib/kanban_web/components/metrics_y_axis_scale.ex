defmodule KanbanWeb.MetricsYAxisScale do
  @moduledoc """
  Nice-number Y-axis scaling for the metrics charts.

  Given a data peak (or a series of values), returns a rounded chart maximum
  and an evenly-spaced list of tick values running from zero to that maximum.

  The existing chart scales auto-fit to the raw data peak without rounding,
  which produces tick labels like `9.25 / 18.5 / 27.75 / 37`. This module
  picks a step from the conventional 1-2-5 progression scaled by a power of
  ten, then rounds the maximum **up** to a whole multiple of that step — so a
  peak of `37` yields `0 / 10 / 20 / 30 / 40` instead.

  The returned maximum is never below the data peak, so bars cannot clip.

  Values are unit-agnostic — the caller decides whether they are minutes,
  hours or counts — and nothing here renders markup.
  """

  # Ticks are chosen to land near this many intervals (so roughly five labels
  # including zero), which reads comfortably on the metrics charts.
  @target_intervals 4

  # The classic nice-number thresholds: a normalized step below 1.5 rounds to
  # 1, below 3 to 2, below 7 to 5, and anything larger rolls over to the next
  # decade. This is what keeps steps on the 1-2-5 progression.
  @step_thresholds [{1.5, 1}, {3.0, 2}, {7.0, 5}]
  @step_rollover 10

  # An empty series or a zero peak has no scale to fit, so fall back to a
  # small honest axis rather than dividing by zero or inventing headroom.
  @empty_scale %{max: 4, ticks: [0, 1, 2, 3, 4]}

  @type t :: %{max: number(), ticks: [number()]}

  @doc """
  Returns `%{max: maximum, ticks: [...]}` for a data peak or a series.

  Accepts either a number (the peak itself) or a list of numbers (the series,
  whose peak is taken). A zero peak, an empty series, and any non-positive
  value all yield the default empty-state scale.

  ## Examples

      iex> KanbanWeb.MetricsYAxisScale.scale(37)
      %{max: 40, ticks: [0, 10, 20, 30, 40]}

      iex> KanbanWeb.MetricsYAxisScale.scale(5)
      %{max: 5, ticks: [0, 1, 2, 3, 4, 5]}

      iex> KanbanWeb.MetricsYAxisScale.scale([12, 87, 40])
      %{max: 100, ticks: [0, 20, 40, 60, 80, 100]}

      iex> KanbanWeb.MetricsYAxisScale.scale(0)
      %{max: 4, ticks: [0, 1, 2, 3, 4]}

      iex> KanbanWeb.MetricsYAxisScale.scale([])
      %{max: 4, ticks: [0, 1, 2, 3, 4]}

  """
  @spec scale(number() | [number()]) :: t()
  def scale([]), do: @empty_scale

  def scale(values) when is_list(values) do
    values
    |> Enum.max(fn -> 0 end)
    |> scale()
  end

  def scale(peak) when is_number(peak) and peak > 0 do
    step = nice_step(peak)
    precision = precision_for(step)
    max = cast(Float.ceil(peak / step) * step, precision)

    %{max: max, ticks: ticks(max, step, precision)}
  end

  def scale(peak) when is_number(peak), do: @empty_scale

  # The smallest 1-2-5 step (scaled by a power of ten) that covers the peak in
  # roughly @target_intervals intervals.
  defp nice_step(peak) do
    raw_step = peak / @target_intervals
    magnitude = :math.pow(10, Float.floor(:math.log10(raw_step)))
    normalized = raw_step / magnitude

    multiplier =
      Enum.find_value(@step_thresholds, @step_rollover, fn {threshold, multiplier} ->
        normalized < threshold && multiplier
      end)

    multiplier * magnitude
  end

  defp ticks(max, step, precision) do
    count = round(max / step)

    Enum.map(0..count, fn index -> cast(index * step, precision) end)
  end

  # Sub-unit steps need decimals; anything from 1 up is reported as a whole
  # number so labels never carry a `.0` or a float-arithmetic tail like
  # `0.30000000000000004`.
  defp precision_for(step) when step >= 1, do: 0

  defp precision_for(step) do
    step |> :math.log10() |> Float.floor() |> abs() |> trunc()
  end

  defp cast(value, 0), do: round(value)
  defp cast(value, precision), do: Float.round(value / 1, precision)
end
