defmodule Kanban.Push.AdapterTest do
  # No test here sends a push: the platform adapters' responses are mapped from
  # structs built in the test, the facade is exercised against the Mox doubles
  # configured in config/test.exs, and no APNs or FCM credentials are ever
  # configured, so no Pigeon dispatcher runs.
  use ExUnit.Case, async: true

  import Mox

  alias Kanban.Devices.Device
  alias Kanban.Push
  alias Kanban.Push.Adapter
  alias Kanban.Push.APNs
  alias Kanban.Push.FCM
  alias Kanban.Push.Payload

  setup :verify_on_exit!

  @collapse_id "review:task:4812"

  defp device(attrs \\ []) do
    struct!(
      %Device{platform: :ios, push_token: "device-token", push_environment: :sandbox},
      attrs
    )
  end

  defp payload(attrs \\ []) do
    struct!(
      %Payload{collapse_id: @collapse_id, title: "Review W12", body: "Agent finished", badge: 3},
      attrs
    )
  end

  # What each adapter makes of the notification Pigeon answers with.
  defp apns_result(response), do: APNs.map_response(%Pigeon.APNS.Notification{response: response})
  defp fcm_result(response), do: FCM.map_response(%Pigeon.FCM.Notification{response: response})

  describe "APNs response mapping" do
    test "APNs maps 410 Unregistered to unregistered" do
      assert apns_result(:unregistered) == :unregistered
    end

    test "success is ok, 429 is rate_limited, an expired JWT and other reasons pass through" do
      assert apns_result(:success) == :ok
      assert apns_result(:too_many_requests) == {:error, :rate_limited}

      assert apns_result(:expired_provider_token) ==
               {:error, :expired_provider_token}

      # Only 410 Unregistered clears a token (§7.8); a malformed token does not.
      assert apns_result(:bad_device_token) == {:error, :bad_device_token}
      assert apns_result(:timeout) == {:error, :timeout}
      assert apns_result(:not_started) == {:error, :not_started}
    end

    test "a notification with no response, or anything else, is an unknown error" do
      assert apns_result(nil) == {:error, :unknown_error}
      assert APNs.map_response(:not_a_notification) == {:error, :unknown_error}
    end
  end

  describe "FCM response mapping" do
    test "FCM maps UNREGISTERED to unregistered" do
      assert fcm_result(:unregistered) == :unregistered
    end

    test "success is ok, QUOTA_EXCEEDED is rate_limited and other reasons pass through" do
      assert fcm_result(:success) == :ok
      assert fcm_result(:quota_exceeded) == {:error, :rate_limited}
      assert fcm_result(:unavailable) == {:error, :unavailable}
      assert fcm_result(:invalid_argument) == {:error, :invalid_argument}
    end

    test "a notification with no response, or anything else, is an unknown error" do
      assert fcm_result(nil) == {:error, :unknown_error}
      assert FCM.map_response(%{}) == {:error, :unknown_error}
    end
  end

  describe "credentials" do
    test "no credentials returns not_configured" do
      assert APNs.config() == {:error, :not_configured}
      assert FCM.config() == {:error, :not_configured}

      push = payload()
      assert APNs.send(device(), push) == {:error, :not_configured}
      assert FCM.send(%{device() | platform: :android}, push) == {:error, :not_configured}

      # With nothing configured no dispatcher was started, so nothing could
      # have reached Apple or Google.
      assert Kanban.Push.Supervisor.children({:error, :not_configured}, {:error, :not_configured}) ==
               []

      refute Process.whereis(APNs.SandboxDispatcher)
      refute Process.whereis(APNs.ProductionDispatcher)
      refute Process.whereis(FCM.Dispatcher)
    end

    test "credentials need every key present and non-blank" do
      keys = [:key, :service_account]
      full = [key: "k", service_account: %{"type" => "service_account"}]

      assert Adapter.credentials(full, keys) == {:ok, full}
      assert Adapter.credentials([], keys) == :error
      assert Adapter.credentials([key: "k"], keys) == :error
      assert Adapter.credentials([key: "  ", service_account: %{"a" => 1}], keys) == :error
      assert Adapter.credentials([key: "k", service_account: %{}], keys) == :error
      assert Adapter.credentials([key: :k, service_account: %{"a" => 1}], keys) == :error
    end

    test "configured credentials give a dispatcher per platform and APNs endpoint" do
      apns =
        {:ok, key: "pem-secret", key_identifier: "KEYID12345", team_id: "TEAMID1234", topic: "t"}

      fcm = {:ok, project_id: "kanban-test", service_account: %{"private_key" => "sa-secret"}}

      children = Kanban.Push.Supervisor.children(apns, fcm)

      assert Enum.map(children, & &1.id) ==
               [
                 APNs.SandboxDispatcher,
                 APNs.ProductionDispatcher,
                 Kanban.Push.Goth,
                 FCM.Dispatcher
               ]

      assert Enum.map(children, & &1.start) == [
               {Kanban.Push.Supervisor, :start_apns, [APNs.SandboxDispatcher, :dev]},
               {Kanban.Push.Supervisor, :start_apns, [APNs.ProductionDispatcher, :prod]},
               {Kanban.Push.Supervisor, :start_goth, []},
               {Kanban.Push.Supervisor, :start_fcm, []}
             ]

      # The specs name only what to start; the credentials are read at start
      # time, so a supervisor report about a child can never print them.
      refute inspect(children) =~ "secret"
    end

    test "a child started without credentials returns not_configured" do
      assert Kanban.Push.Supervisor.start_apns(APNs.SandboxDispatcher, :dev) ==
               {:error, :not_configured}

      assert Kanban.Push.Supervisor.start_goth() == {:error, :not_configured}
      assert Kanban.Push.Supervisor.start_fcm() == {:error, :not_configured}
    end
  end

  describe "notification building" do
    test "builds the APNs collapse id and the FCM tag" do
      apns = APNs.build_notification(device(), payload(), "com.example.app")

      assert apns.collapse_id == @collapse_id
      assert apns.topic == "com.example.app"
      assert apns.device_token == "device-token"

      assert apns.payload["aps"]["alert"] == %{
               "title" => "Review W12",
               "body" => "Agent finished"
             }

      assert apns.payload["aps"]["badge"] == 3
      assert apns.payload["aps"]["mutable-content"] == 1
      assert apns.payload["collapse_id"] == @collapse_id

      fcm = [platform: :android] |> device() |> FCM.build_notification(payload())

      assert fcm.target == {:token, "device-token"}
      assert fcm.android["notification"]["tag"] == @collapse_id
      assert fcm.android["collapse_key"] == @collapse_id
      assert fcm.notification == %{"title" => "Review W12", "body" => "Agent finished"}
      assert fcm.data["collapse_id"] == @collapse_id
    end

    test "a payload with no title or body is a silent, data-only push" do
      silent = payload(title: nil, body: "", badge: nil, data: %{count: 2})

      apns = APNs.build_notification(device(), silent, "com.example.app")
      refute Map.has_key?(apns.payload["aps"], "alert")
      refute Map.has_key?(apns.payload["aps"], "badge")
      assert apns.payload["aps"]["content-available"] == 1
      assert apns.push_type == "background"
      assert apns.priority == 5
      assert apns.collapse_id == @collapse_id

      fcm = [platform: :android] |> device() |> FCM.build_notification(silent)
      assert fcm.notification == nil
      assert fcm.android == %{"collapse_key" => @collapse_id}
      assert fcm.data == %{"count" => "2", "collapse_id" => @collapse_id}
    end

    test "a silent payload never carries a badge, a visible one carries 0" do
      silent = APNs.build_notification(device(), payload(title: nil, body: nil, badge: 4), "t")
      refute Map.has_key?(silent.payload["aps"], "badge")
      assert silent.push_type == "background"

      # 0 is in range: it clears the app icon's count.
      cleared = APNs.build_notification(device(), payload(badge: 0), "t")
      assert cleared.payload["aps"]["badge"] == 0

      # A negative badge is not a count and is left out.
      negative = APNs.build_notification(device(), payload(badge: -1), "t")
      refute Map.has_key?(negative.payload["aps"], "badge")
    end

    test "a data key named aps never replaces the APNs aps dictionary" do
      apns = APNs.build_notification(device(), payload(data: %{"aps" => "x"}), "t")

      assert apns.payload["aps"]["alert"]["title"] == "Review W12"
    end
  end

  describe "adapter choice" do
    test "the configured adapter is chosen per platform" do
      assert Push.adapter_for(:ios) == {:ok, Kanban.Push.APNsMock}
      assert Push.adapter_for(:android) == {:ok, Kanban.Push.FCMMock}

      ios = device()
      android = device(platform: :android, push_token: "android-token")
      push = payload()

      expect(Kanban.Push.APNsMock, :send, fn ^ios, ^push -> :ok end)
      expect(Kanban.Push.FCMMock, :send, fn ^android, ^push -> :unregistered end)

      assert Push.send(ios, push) == :ok
      assert Push.send(android, push) == :unregistered
    end

    test "an unknown platform has no adapter" do
      assert Push.adapter_for(:windows) == {:error, :unsupported_platform}
      assert Push.adapter_for(nil) == {:error, :unsupported_platform}

      assert [platform: nil] |> device() |> Push.send(payload()) ==
               {:error, :unsupported_platform}
    end
  end

  describe "a device with no push token" do
    test "the facade calls no adapter" do
      # verify_on_exit! fails the test if either mock is called.
      assert [push_token: nil] |> device() |> Push.send(payload()) == {:error, :no_push_token}
      assert [push_token: ""] |> device() |> Push.send(payload()) == {:error, :no_push_token}
    end

    test "the adapter helper refuses it" do
      assert [push_token: nil] |> device() |> Adapter.push_token() == {:error, :no_push_token}
      assert Adapter.push_token(device()) == {:ok, "device-token"}
    end
  end

  describe "APNs endpoint choice" do
    test "push_environment picks the sandbox or production dispatcher" do
      assert APNs.dispatcher_for(:sandbox) == {:ok, APNs.SandboxDispatcher}
      assert APNs.dispatcher_for(:production) == {:ok, APNs.ProductionDispatcher}
      assert APNs.dispatcher_for(nil) == {:error, :no_push_environment}
    end
  end

  describe "payload" do
    test "string_data stringifies keys and values and adds the collapse id" do
      assert [data: %{"kind" => :review, count: 2}] |> payload() |> Payload.string_data() == %{
               "count" => "2",
               "kind" => "review",
               "collapse_id" => @collapse_id
             }
    end

    test "visible? is true only with a non-empty title or body" do
      assert Payload.visible?(payload())
      assert [title: nil] |> payload() |> Payload.visible?()
      refute [title: nil, body: nil] |> payload() |> Payload.visible?()
      refute [title: "", body: ""] |> payload() |> Payload.visible?()
    end
  end
end
