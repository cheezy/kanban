defmodule KanbanWeb.TimezoneTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.Timezone

  describe "validate_timezone/1" do
    test "returns the zone for a valid IANA string" do
      assert Timezone.validate_timezone(%{"timezone" => "America/Edmonton"}) ==
               "America/Edmonton"
    end

    test "falls back to UTC for an unknown zone" do
      assert Timezone.validate_timezone(%{"timezone" => "Not/ARealZone"}) == "Etc/UTC"
    end

    test "falls back to UTC for a non-string timezone value" do
      assert Timezone.validate_timezone(%{"timezone" => 123}) == "Etc/UTC"
    end

    test "falls back to UTC when the timezone param is missing" do
      assert Timezone.validate_timezone(%{}) == "Etc/UTC"
    end

    test "falls back to UTC for nil params" do
      assert Timezone.validate_timezone(nil) == "Etc/UTC"
    end

    test "falls back to UTC for a zone over the length cap" do
      assert Timezone.validate_timezone(%{"timezone" => String.duplicate("A", 65)}) == "Etc/UTC"
    end
  end

  describe "parse_timezone/1" do
    test "returns {:ok, zone} for a valid IANA string" do
      assert Timezone.parse_timezone("America/Edmonton") == {:ok, "America/Edmonton"}
    end

    test "accepts a valid zone alias" do
      assert Timezone.parse_timezone("US/Eastern") == {:ok, "US/Eastern"}
    end

    test "accepts Etc/UTC as a valid zone rather than a fallback" do
      assert Timezone.parse_timezone("Etc/UTC") == {:ok, "Etc/UTC"}
    end

    test "returns :error for an unknown zone" do
      assert Timezone.parse_timezone("Not/ARealZone") == :error
    end

    test "returns :error for a zone over 64 bytes" do
      assert Timezone.parse_timezone("America/" <> String.duplicate("x", 57)) == :error
    end

    test "returns :error for a non-string" do
      assert Timezone.parse_timezone(nil) == :error
      assert Timezone.parse_timezone(123) == :error
    end
  end

  describe "resolve_timezone/1" do
    test "returns a valid zone unchanged" do
      assert Timezone.resolve_timezone("Asia/Tokyo") == "Asia/Tokyo"
    end

    test "falls back to UTC for an unknown, oversized or non-string zone" do
      assert Timezone.resolve_timezone("Not/ARealZone") == "Etc/UTC"
      assert Timezone.resolve_timezone("America/" <> String.duplicate("x", 57)) == "Etc/UTC"
      assert Timezone.resolve_timezone(nil) == "Etc/UTC"
    end
  end

  describe "request_timezone/2" do
    test "prefers a valid session zone over the timezone param" do
      assert Timezone.request_timezone("Europe/Berlin", %{"timezone" => "Pacific/Midway"}) ==
               "Europe/Berlin"
    end

    test "falls back to the timezone param when the session zone is missing or invalid" do
      assert Timezone.request_timezone(nil, %{"timezone" => "Pacific/Midway"}) ==
               "Pacific/Midway"

      assert Timezone.request_timezone("Not/AZone", %{"timezone" => "Pacific/Midway"}) ==
               "Pacific/Midway"
    end

    test "falls back to UTC when neither source is valid" do
      assert Timezone.request_timezone(nil, %{"timezone" => "Not/AZone"}) == "Etc/UTC"
      assert Timezone.request_timezone(nil, %{}) == "Etc/UTC"
      assert Timezone.request_timezone(nil, nil) == "Etc/UTC"
    end
  end

  describe "browser_timezone/1" do
    test "returns UTC on the static (disconnected) render" do
      assert Timezone.browser_timezone(%Phoenix.LiveView.Socket{}) == "Etc/UTC"
    end
  end
end
