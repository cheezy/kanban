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
  end

  describe "browser_timezone/1" do
    test "returns UTC on the static (disconnected) render" do
      assert Timezone.browser_timezone(%Phoenix.LiveView.Socket{}) == "Etc/UTC"
    end
  end
end
