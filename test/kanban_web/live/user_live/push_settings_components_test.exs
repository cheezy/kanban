defmodule KanbanWeb.UserLive.PushSettingsComponentsTest do
  use ExUnit.Case, async: true

  alias Kanban.Notifications.PushSettings
  alias KanbanWeb.UserLive.PushSettingsComponents

  defp view(attrs \\ %{}) do
    Map.merge(
      %{
        mode: :decisions,
        switches: PushSettings.preset(:decisions),
        quiet_hours_enabled: false,
        quiet_start: ~T[22:00:00],
        quiet_end: ~T[07:00:00],
        time_zone: nil
      },
      attrs
    )
  end

  describe "zones/0" do
    test "every zone is one the tz database knows" do
      for zone <- PushSettingsComponents.zones() do
        assert {:ok, _now} = DateTime.now(zone), "#{zone} is not a known zone"
      end
    end

    test "has no duplicates" do
      zones = PushSettingsComponents.zones()
      assert zones == Enum.uniq(zones)
    end
  end

  describe "zone_options/2" do
    test "lists the curated zones sorted, with readable labels" do
      options = PushSettingsComponents.zone_options(nil, nil)
      values = Enum.map(options, &elem(&1, 1))

      assert values == Enum.sort(PushSettingsComponents.zones())
      assert {"America/Los Angeles", "America/Los_Angeles"} in options
    end

    test "adds the stored and browser zones once" do
      values =
        "Asia/Kathmandu"
        |> PushSettingsComponents.zone_options("Europe/Berlin")
        |> Enum.map(&elem(&1, 1))

      assert "Asia/Kathmandu" in values
      assert Enum.count(values, &(&1 == "Europe/Berlin")) == 1
      assert length(values) == length(PushSettingsComponents.zones()) + 1
    end

    test "ignores an unknown zone" do
      values =
        "Mars/Base"
        |> PushSettingsComponents.zone_options("")
        |> Enum.map(&elem(&1, 1))

      refute "Mars/Base" in values
      refute "" in values
    end
  end

  describe "quiet_params/2" do
    test "formats times to the minute and keeps the stored zone" do
      params =
        %{quiet_hours_enabled: true, time_zone: "Europe/Paris"}
        |> view()
        |> PushSettingsComponents.quiet_params("Asia/Tokyo")

      assert params == %{
               "quiet_hours_enabled" => true,
               "quiet_start" => "22:00",
               "quiet_end" => "07:00",
               "time_zone" => "Europe/Paris"
             }
    end

    test "suggests the browser zone when none is stored" do
      assert %{"time_zone" => "Asia/Tokyo"} =
               PushSettingsComponents.quiet_params(view(), "Asia/Tokyo")
    end

    test "suggests no zone for the UTC fallback, nil or an unknown zone" do
      for browser <- ["Etc/UTC", nil, "Mars/Base"] do
        assert %{"time_zone" => ""} = PushSettingsComponents.quiet_params(view(), browser)
      end
    end
  end

  describe "quiet_errors/1" do
    defp errors_for(attrs) do
      view()
      |> PushSettings.request_changeset(attrs)
      |> PushSettingsComponents.quiet_errors()
    end

    test "maps a range that starts when it ends" do
      assert %{quiet_end: ["Quiet hours can't start and end at the same time."]} =
               errors_for(%{"quiet_start" => "09:00", "quiet_end" => "09:00"})
    end

    test "maps an invalid time" do
      assert %{quiet_start: ["Enter a time, such as 22:00."]} =
               errors_for(%{"quiet_start" => "25:99"})
    end

    test "maps an unknown zone" do
      assert %{time_zone: ["Choose a time zone from the list."]} =
               errors_for(%{"time_zone" => "Mars/Base"})
    end

    test "maps quiet hours turned on with no zone" do
      assert %{quiet_hours_enabled: ["Choose a time zone to turn on quiet hours."]} =
               errors_for(%{"quiet_hours_enabled" => "true"})
    end

    test "leaves out errors on fields the quiet hours form does not show" do
      assert errors_for(%{"mode" => "loud", "switches" => %{"task_assigned" => true}}) == %{}
    end
  end
end
