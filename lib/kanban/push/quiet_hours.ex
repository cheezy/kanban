defmodule Kanban.Push.QuietHours do
  @moduledoc """
  Whether a moment falls inside a person's quiet hours
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.9, decision 5).

  Quiet hours are read in `user_push_settings.time_zone`, the one zone the
  person chose, and never in a device's zone: a person travelling with the
  phone keeps the quiet hours of the zone they set until they change it.

  ## Periods, not wall-clock times

  A quiet period runs from the first moment the clock in the zone reads
  `quiet_start` to the first moment after it that the clock reads
  `quiet_end`. A start later than the end, such as 22:00 to 07:00, crosses
  midnight and ends on the next local day. The end is excluded, so 07:00 is
  outside 22:00 to 07:00 while 06:59 is inside.

  Both ends are worked out as instants, so a daylight-saving change cannot
  stretch or repeat a period:

    * a time the clock skips (a spring-forward gap) resolves to the first
      instant after the gap;
    * a time the clock reads twice (a fall-back hour) resolves to its first
      reading, so a period ends once, and the repeated hour that follows is
      outside it.

  Settings with quiet hours off, no time zone, a zone the tz database does
  not know or a start equal to the end never hold anything.

  The functions take the `Kanban.Notifications.PushSettings` row or any map
  with its `quiet_hours_enabled`, `quiet_start`, `quiet_end` and `time_zone`
  fields (a settings view), or `nil` for a person with no row.
  """

  @typedoc "A `PushSettings` row, a settings view, or `nil`."
  @type settings ::
          %{
            required(:quiet_hours_enabled) => boolean(),
            required(:quiet_start) => Time.t(),
            required(:quiet_end) => Time.t(),
            required(:time_zone) => String.t() | nil,
            optional(atom()) => term()
          }
          | nil

  @utc "Etc/UTC"

  @doc """
  True when `now` is inside one of the quiet periods `settings` give.
  """
  @spec inside?(settings(), DateTime.t()) :: boolean()
  def inside?(settings, %DateTime{} = now) do
    settings
    |> periods(now)
    |> Enum.any?(fn {start, stop} -> on_or_after?(now, start) and before?(now, stop) end)
  end

  @doc """
  The start of the quiet period `now` is inside, in UTC and to the second,
  or `nil` when `now` is outside quiet hours.
  """
  @spec current_start(settings(), DateTime.t()) :: DateTime.t() | nil
  def current_start(settings, %DateTime{} = now) do
    settings
    |> periods(now)
    |> Enum.find_value(fn {start, stop} ->
      if on_or_after?(now, start) and before?(now, stop), do: start
    end)
  end

  @doc """
  The end of the latest quiet period that ended at or before `now`, in UTC
  and to the second, or `nil` when `settings` hold nothing.
  """
  @spec last_ended(settings(), DateTime.t()) :: DateTime.t() | nil
  def last_ended(settings, %DateTime{} = now) do
    settings
    |> periods(now)
    |> Enum.map(fn {_start, stop} -> stop end)
    |> Enum.filter(&on_or_after?(now, &1))
    |> Enum.max(DateTime, fn -> nil end)
  end

  # The periods starting on the local day of `now` and the two days before,
  # which hold every period that can contain `now` or have just ended.
  defp periods(
         %{quiet_hours_enabled: true, quiet_start: %Time{} = start, quiet_end: %Time{} = stop} =
           settings,
         now
       )
       when start != stop do
    with zone when is_binary(zone) <- Map.get(settings, :time_zone),
         {:ok, local} <- DateTime.shift_zone(now, zone) do
      local |> DateTime.to_date() |> periods_from(start, stop, zone)
    else
      _no_zone -> []
    end
  end

  defp periods(_settings, _now), do: []

  defp periods_from(today, start, stop, zone) do
    for offset <- [-2, -1, 0],
        period = period(Date.add(today, offset), start, stop, zone),
        period != nil,
        do: period
  end

  defp period(day, start, stop, zone) do
    stop_day = if Time.compare(start, stop) == :gt, do: Date.add(day, 1), else: day

    from = boundary(day, start, zone)
    to = boundary(stop_day, stop, zone)

    # Both ends inside one skipped hour make an empty period.
    if before?(from, to), do: {from, to}, else: nil
  end

  # The first instant the clock in `zone` reads `time` on `date`, in UTC.
  # The zone is known here: `periods/2` shifted `now` into it.
  defp boundary(date, time, zone) do
    case DateTime.new(date, time, zone) do
      {:ok, local} -> utc(local)
      {:ambiguous, first, _second} -> utc(first)
      {:gap, _just_before, just_after} -> utc(just_after)
    end
  end

  defp utc(local), do: local |> DateTime.shift_zone!(@utc) |> DateTime.truncate(:second)

  defp before?(a, b), do: DateTime.compare(a, b) == :lt
  defp on_or_after?(a, b), do: DateTime.compare(a, b) != :lt
end
