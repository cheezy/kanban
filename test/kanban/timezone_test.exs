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
end
