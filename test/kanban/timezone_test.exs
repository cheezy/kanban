defmodule Kanban.TimezoneTest do
  use ExUnit.Case, async: true

  alias Kanban.Timezone

  describe "local_today/1" do
    test "returns the viewer's local date for a valid zone" do
      expected = "America/Edmonton" |> DateTime.now!() |> DateTime.to_date()
      assert Timezone.local_today("America/Edmonton") == expected
    end

    test "returns the UTC date for the UTC zone" do
      assert Timezone.local_today("Etc/UTC") == Date.utc_today()
    end

    test "falls back to the UTC date for an unknown zone" do
      assert Timezone.local_today("Not/ARealZone") == Date.utc_today()
    end
  end

  describe "local_date/2" do
    test "shifts a UTC timestamp west of UTC into the previous local day" do
      # 05:30 UTC is 23:30 the previous day in Edmonton (MDT, UTC-6) in June.
      assert Timezone.local_date(~U[2026-06-21 05:30:00Z], "America/Edmonton") ==
               ~D[2026-06-20]
    end

    test "keeps the same calendar date for the UTC zone" do
      assert Timezone.local_date(~U[2026-06-21 05:30:00Z], "Etc/UTC") == ~D[2026-06-21]
    end

    test "falls back to the UTC date when the zone is unknown" do
      assert Timezone.local_date(~U[2026-06-21 05:30:00Z], "Not/ARealZone") ==
               ~D[2026-06-21]
    end
  end

  describe "start_of_local_day/2" do
    test "returns the UTC instant of local midnight for a zone west of UTC" do
      # Midnight Jun 21 in Edmonton (MDT, UTC-6) is 06:00 UTC.
      assert Timezone.start_of_local_day(~D[2026-06-21], "America/Edmonton") ==
               ~U[2026-06-21 06:00:00Z]
    end

    test "returns midnight UTC for the UTC zone" do
      assert Timezone.start_of_local_day(~D[2026-06-21], "Etc/UTC") ==
               ~U[2026-06-21 00:00:00Z]
    end

    test "falls back to midnight UTC for an unknown zone" do
      assert Timezone.start_of_local_day(~D[2026-06-21], "Not/ARealZone") ==
               ~U[2026-06-21 00:00:00Z]
    end
  end
end
