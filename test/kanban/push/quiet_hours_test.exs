defmodule Kanban.Push.QuietHoursTest do
  @moduledoc """
  Tests for `Kanban.Push.QuietHours`: windows that cross midnight, the
  settings' time zone, settings that never hold, and daylight-saving nights.
  """
  use ExUnit.Case, async: true

  alias Kanban.Notifications.PushSettings
  alias Kanban.Push.QuietHours

  defp settings(attrs \\ %{}) do
    Map.merge(
      %{
        quiet_hours_enabled: true,
        quiet_start: ~T[22:00:00],
        quiet_end: ~T[07:00:00],
        time_zone: "Europe/London"
      },
      attrs
    )
  end

  # A wall-clock time in `zone`, as a UTC instant.
  defp at(date, time, zone \\ "Europe/London") do
    date |> DateTime.new!(time, zone) |> DateTime.shift_zone!("Etc/UTC")
  end

  describe "inside?/2" do
    test "22:00 to 07:00 contains 23:30 and 06:59 but not 07:00" do
      s = settings()

      assert QuietHours.inside?(s, at(~D[2026-01-14], ~T[23:30:00]))
      assert QuietHours.inside?(s, at(~D[2026-01-15], ~T[06:59:00]))
      assert QuietHours.inside?(s, at(~D[2026-01-14], ~T[22:00:00]))
      assert QuietHours.inside?(s, at(~D[2026-01-15], ~T[00:00:00]))
      refute QuietHours.inside?(s, at(~D[2026-01-15], ~T[07:00:00]))
      refute QuietHours.inside?(s, at(~D[2026-01-14], ~T[21:59:59]))
      refute QuietHours.inside?(s, at(~D[2026-01-15], ~T[12:00:00]))
    end

    test "a window that does not cross midnight holds only within the day" do
      s = settings(%{quiet_start: ~T[09:00:00], quiet_end: ~T[17:00:00]})

      assert QuietHours.inside?(s, at(~D[2026-01-14], ~T[09:00:00]))
      assert QuietHours.inside?(s, at(~D[2026-01-14], ~T[16:59:59]))
      refute QuietHours.inside?(s, at(~D[2026-01-14], ~T[17:00:00]))
      refute QuietHours.inside?(s, at(~D[2026-01-14], ~T[23:30:00]))
      refute QuietHours.inside?(s, at(~D[2026-01-14], ~T[08:59:59]))
    end

    test "uses the settings time zone, not the device zone" do
      # 23:30 in Tokyo is 14:30 UTC: 14:30 in London, outside its quiet hours.
      tokyo_night = at(~D[2026-01-14], ~T[23:30:00], "Asia/Tokyo")

      assert %{time_zone: "Asia/Tokyo"} |> settings() |> QuietHours.inside?(tokyo_night)
      refute %{time_zone: "Europe/London"} |> settings() |> QuietHours.inside?(tokyo_night)

      # A person travelling with the phone keeps the zone they set.
      london_night = at(~D[2026-01-14], ~T[23:30:00])
      assert QuietHours.inside?(settings(), london_night)
      refute %{time_zone: "Asia/Tokyo"} |> settings() |> QuietHours.inside?(london_night)
    end

    test "a zone west of UTC is read in that zone" do
      s = settings(%{time_zone: "America/New_York"})

      # 23:30 in New York is 04:30 UTC the next day.
      assert QuietHours.inside?(s, ~U[2026-01-15 04:30:00Z])
      refute QuietHours.inside?(s, ~U[2026-01-15 12:00:00Z])
      refute QuietHours.inside?(s, ~U[2026-01-14 23:30:00Z])
    end

    test "disabled quiet hours never hold" do
      night = at(~D[2026-01-14], ~T[23:30:00])

      refute %{quiet_hours_enabled: false} |> settings() |> QuietHours.inside?(night)
      refute QuietHours.inside?(nil, night)
      refute %{time_zone: nil} |> settings() |> QuietHours.inside?(night)
      refute %{time_zone: "Not/AZone"} |> settings() |> QuietHours.inside?(night)
      refute %{quiet_end: ~T[22:00:00]} |> settings() |> QuietHours.inside?(night)
    end

    test "takes the PushSettings row and its defaults" do
      row = %PushSettings{user_id: 1, quiet_hours_enabled: true, time_zone: "Europe/London"}

      assert QuietHours.inside?(row, at(~D[2026-01-14], ~T[23:30:00]))
      refute QuietHours.inside?(%PushSettings{user_id: 1}, at(~D[2026-01-14], ~T[23:30:00]))
    end

    test "a daylight-saving change night still ends once" do
      # 25 October 2026: London's clocks go back from 02:00 BST to 01:00 GMT,
      # so the clock reads 01:30 twice.
      s = settings(%{quiet_end: ~T[01:30:00]})

      # The first 01:30 (BST) is 00:30 UTC.
      assert QuietHours.inside?(s, ~U[2026-10-25 00:29:59Z])
      refute QuietHours.inside?(s, ~U[2026-10-25 00:30:00Z])
      # The repeated hour, 01:00 to 02:00 GMT, is outside: the period is over.
      refute QuietHours.inside?(s, ~U[2026-10-25 01:00:00Z])
      refute QuietHours.inside?(s, ~U[2026-10-25 01:30:00Z])
      refute QuietHours.inside?(s, ~U[2026-10-25 01:59:59Z])

      assert QuietHours.last_ended(s, ~U[2026-10-25 03:00:00Z]) == ~U[2026-10-25 00:30:00Z]
    end

    test "a time the spring-forward gap skips resolves to the end of the gap" do
      # 29 March 2026: London's clocks go from 01:00 GMT to 02:00 BST, so the
      # clock never reads 01:30; quiet hours ending then end at 02:00 BST.
      s = settings(%{quiet_end: ~T[01:30:00]})

      assert QuietHours.inside?(s, ~U[2026-03-29 00:59:59Z])
      refute QuietHours.inside?(s, ~U[2026-03-29 01:00:00Z])
      assert QuietHours.last_ended(s, ~U[2026-03-29 02:00:00Z]) == ~U[2026-03-29 01:00:00Z]

      # A start in the gap starts at 02:00 BST.
      starts_in_gap = settings(%{quiet_start: ~T[01:30:00], quiet_end: ~T[06:00:00]})
      refute QuietHours.inside?(starts_in_gap, ~U[2026-03-29 00:59:59Z])
      assert QuietHours.inside?(starts_in_gap, ~U[2026-03-29 01:00:00Z])
    end

    test "a window wholly inside the skipped hour holds nothing that night" do
      s = settings(%{quiet_start: ~T[01:10:00], quiet_end: ~T[01:40:00]})

      refute QuietHours.inside?(s, ~U[2026-03-29 01:00:00Z])
      assert QuietHours.last_ended(s, ~U[2026-03-29 12:00:00Z]) == ~U[2026-03-28 01:40:00Z]
      assert QuietHours.inside?(s, ~U[2026-03-30 00:15:00Z])
    end
  end

  describe "current_start/2" do
    test "the start of the period now is inside, or nil outside" do
      s = settings()

      assert QuietHours.current_start(s, at(~D[2026-01-15], ~T[06:00:00])) ==
               ~U[2026-01-14 22:00:00Z]

      assert QuietHours.current_start(s, at(~D[2026-01-15], ~T[12:00:00])) == nil
      assert QuietHours.current_start(nil, at(~D[2026-01-15], ~T[06:00:00])) == nil
    end
  end

  describe "last_ended/2" do
    test "the latest period end at or before now" do
      s = settings()

      assert QuietHours.last_ended(s, at(~D[2026-01-15], ~T[07:00:00])) ==
               ~U[2026-01-15 07:00:00Z]

      assert QuietHours.last_ended(s, at(~D[2026-01-15], ~T[12:00:00])) ==
               ~U[2026-01-15 07:00:00Z]

      # Inside quiet hours, the previous period's end.
      assert QuietHours.last_ended(s, at(~D[2026-01-15], ~T[23:30:00])) ==
               ~U[2026-01-15 07:00:00Z]

      assert QuietHours.last_ended(s, at(~D[2026-01-16], ~T[06:00:00])) ==
               ~U[2026-01-15 07:00:00Z]
    end

    test "a same-day window before its start gives yesterday's end" do
      s = settings(%{quiet_start: ~T[09:00:00], quiet_end: ~T[17:00:00]})

      assert QuietHours.last_ended(s, at(~D[2026-01-15], ~T[08:00:00])) ==
               ~U[2026-01-14 17:00:00Z]
    end

    test "is nil when the settings hold nothing" do
      now = ~U[2026-01-15 12:00:00Z]

      assert QuietHours.last_ended(nil, now) == nil
      assert %{quiet_hours_enabled: false} |> settings() |> QuietHours.last_ended(now) == nil
      assert %{time_zone: nil} |> settings() |> QuietHours.last_ended(now) == nil
    end
  end
end
