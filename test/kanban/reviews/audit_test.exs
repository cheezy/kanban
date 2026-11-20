defmodule Kanban.Reviews.AuditTest do
  use ExUnit.Case, async: true

  alias Kanban.Devices.Device
  alias Kanban.Reviews.Audit

  @reviewer %{id: 7}

  defp device(attrs \\ %{}) do
    struct!(
      %Device{id: 3, user_id: 7, platform: :ios, device_class: :phone, app_version: "1.2.0 (9)"},
      attrs
    )
  end

  describe "context/2" do
    test "the web, with no options" do
      assert Audit.context([], @reviewer) == %{
               via: :web,
               device_id: nil,
               device_class: nil,
               app_version: nil,
               approval_key: false
             }
    end

    test "a device sets via from its platform and records its class and version" do
      assert Audit.context([device: device(), approval_key: true], @reviewer) == %{
               via: :ios,
               device_id: 3,
               device_class: :phone,
               app_version: "1.2.0 (9)",
               approval_key: true
             }

      assert %{via: :android, device_class: :tablet} =
               Audit.context(
                 [device: device(%{platform: :android, device_class: :tablet}), via: :android],
                 @reviewer
               )
    end

    test "approval_key is true only for exactly true" do
      for value <- [false, nil, "true", 1] do
        assert %{approval_key: false} = Audit.context([approval_key: value], @reviewer)
      end
    end

    test "raises on an unknown via, a contradicting via, another user's device or a non-device" do
      assert_raise ArgumentError, ~r/unknown review via/, fn ->
        Audit.context([via: :desktop], @reviewer)
      end

      assert_raise ArgumentError, ~r/does not match/, fn ->
        Audit.context([via: :web, device: device()], @reviewer)
      end

      assert_raise ArgumentError, ~r/another user/, fn ->
        Audit.context([device: device(%{user_id: 8})], @reviewer)
      end

      assert_raise ArgumentError, ~r/must be a Kanban.Devices.Device/, fn ->
        Audit.context([device: %{id: 3}, via: :ios], @reviewer)
      end
    end
  end

  describe "telemetry_metadata/1" do
    test "keeps only via and device_class" do
      context = Audit.context([device: device()], @reviewer)
      assert Audit.telemetry_metadata(context) == %{via: :ios, device_class: :phone}
    end
  end
end
