defmodule Kanban.Workspaces.Export.Importer.TimestampsTest do
  use ExUnit.Case, async: true

  alias Kanban.Workspaces.Export.Importer.Timestamps

  doctest Timestamps, import: true

  describe "to_utc/1" do
    test "converts positive and negative offsets to the UTC instant" do
      assert Timestamps.to_utc(%{
               "inserted_at" => "2026-10-07T15:40:52+02:00",
               "updated_at" => "2026-10-07T15:40:52-05:00"
             }) == %{
               "inserted_at" => ~N[2026-10-07 13:40:52],
               "updated_at" => ~N[2026-10-07 20:40:52]
             }
    end

    test "keeps a Z value's time and a naive value as written" do
      assert Timestamps.to_utc(%{
               "inserted_at" => "2026-10-07T15:40:52Z",
               "updated_at" => "2026-10-07T15:40:52"
             }) == %{
               "inserted_at" => ~N[2026-10-07 15:40:52],
               "updated_at" => "2026-10-07T15:40:52"
             }
    end

    test "keeps fractional seconds when converting an offset" do
      assert Timestamps.to_utc(%{"inserted_at" => "2026-10-07T15:40:52.123456+02:00"}) ==
               %{"inserted_at" => ~N[2026-10-07 13:40:52.123456]}
    end

    test "an offset can move the value across midnight, a month end and a year end" do
      assert Timestamps.to_utc(%{
               "inserted_at" => "2026-10-31T23:30:00-05:00",
               "updated_at" => "2027-01-01T01:00:00+03:00"
             }) == %{
               "inserted_at" => ~N[2026-11-01 04:30:00],
               "updated_at" => ~N[2026-12-31 22:00:00]
             }
    end

    test "leaves invalid strings and non-string values for the cast to judge" do
      values = %{
        "a" => "2026-13-45T00:00:00+02:00",
        "b" => "not a time",
        "c" => "",
        "d" => nil,
        "e" => 42,
        "f" => %{"x" => 1},
        "g" => ["2026-10-07T15:40:52+02:00"]
      }

      assert Timestamps.to_utc(values) == values
    end

    test "an empty map stays empty" do
      assert Timestamps.to_utc(%{}) == %{}
    end
  end
end
