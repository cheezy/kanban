defmodule Kanban.Notifications.PushSettingsTest do
  @moduledoc """
  Tests for the push settings (W2767): `Kanban.Notifications.PushSettings`,
  `Kanban.Notifications.PushSettingsStore` and the push defaults in
  `Kanban.Notifications`.
  """
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.DevicesFixtures

  alias Kanban.Notifications
  alias Kanban.Notifications.Preference
  alias Kanban.Notifications.PushSettings
  alias Kanban.Repo

  @decisions ~w(review_requested task_unclaimed claim_expired after_goal_failed)a
  @updates ~w(task_reviewed goal_completed target_status_changed mentioned)a
  @never ~w(task_assigned board_access_changed weekly_digest comment_added)a

  setup do
    user = user_fixture()
    %{user: user, scope: user_scope_fixture(user)}
  end

  defp put_settings(scope, attrs), do: Notifications.update_push_settings(scope, attrs, opts())
  defp opts, do: [via: :ios, feature: :mobile_app]

  defp put_settings!(scope, attrs) do
    {:ok, view} = put_settings(scope, attrs)
    view
  end

  defp row(user), do: Repo.get(PushSettings, user.id)

  defp errors(scope, attrs) do
    {:error, changeset} = put_settings(scope, attrs)
    errors_on(changeset)
  end

  describe "defaults" do
    test "defaults push on for the four decision events only", ctx do
      for type <- Notifications.event_types() do
        assert Notifications.default_preference(type).push == type in @decisions
      end

      assert PushSettings.push_events() == @decisions ++ @updates
      assert Enum.sort(PushSettings.never_push_events()) == Enum.sort(@never)

      view = Notifications.get_push_settings(ctx.scope)

      assert view == %{
               mode: :decisions,
               switches: Map.new(@decisions ++ @updates, &{&1, &1 in @decisions}),
               quiet_hours_enabled: false,
               quiet_start: ~T[22:00:00],
               quiet_end: ~T[07:00:00],
               time_zone: nil
             }

      # Reading the defaults writes nothing.
      assert row(ctx.user) == nil
      assert Repo.all(Preference) == []
    end

    test "an in-app change on a type with no row keeps its push default", ctx do
      {:ok, pref} =
        Notifications.update_preference(ctx.scope, :review_requested, %{in_app: false})

      assert pref.push
      assert Notifications.get_push_settings(ctx.scope).switches.review_requested
    end

    test "a push change keeps the in-app and email values", ctx do
      {:ok, _} = Notifications.update_preference(ctx.scope, :mentioned, %{email: false})
      put_settings!(ctx.scope, %{"switches" => %{"mentioned" => true}})

      assert %Preference{in_app: true, email: false, push: true} =
               Repo.get_by(Preference, user_id: ctx.user.id, event_type: :mentioned)

      # A later web change to in-app leaves push alone.
      {:ok, pref} = Notifications.update_preference(ctx.scope, :mentioned, %{in_app: false})
      assert %Preference{in_app: false, email: false, push: true} = pref
    end
  end

  describe "every surface" do
    test "the preferences the web page reads report the same push values", ctx do
      put_settings!(ctx.scope, %{"mode" => "every", "switches" => %{"claim_expired" => false}})

      switches = Notifications.get_push_settings(ctx.scope).switches

      web =
        ctx.scope
        |> Notifications.get_preferences()
        |> Map.new(&{&1.event_type, &1.push})

      assert Map.take(web, PushSettings.push_events()) == switches
      refute Enum.any?(PushSettings.never_push_events(), &web[&1])
    end
  end

  describe "modes" do
    test "the every mode turns all eight on; decisions turns updates off", ctx do
      view = put_settings!(ctx.scope, %{"mode" => "every"})
      assert view.mode == :every
      assert view.switches |> Map.values() |> Enum.all?()
      assert Notifications.get_push_settings(ctx.scope) == view

      view = put_settings!(ctx.scope, %{"mode" => "decisions"})
      assert view.switches == Map.new(@decisions ++ @updates, &{&1, &1 in @decisions})
      assert Notifications.get_push_settings(ctx.scope) == view
    end

    test "switches sent with a mode win over its preset", ctx do
      view =
        put_settings!(ctx.scope, %{
          "mode" => "every",
          "switches" => %{"mentioned" => false, "claim_expired" => false}
        })

      refute view.switches.mentioned
      refute view.switches.claim_expired
      assert view.switches.goal_completed
    end

    test "re-sending the current mode keeps changed switches", ctx do
      put_settings!(ctx.scope, %{
        "switches" => %{"review_requested" => false, "mentioned" => true}
      })

      view = put_settings!(ctx.scope, %{"mode" => "decisions"})

      refute view.switches.review_requested
      assert view.switches.mentioned
    end

    test "an unknown mode is refused", ctx do
      assert %{mode: ["is invalid"]} = errors(ctx.scope, %{"mode" => "all"})
      assert row(ctx.user) == nil
    end
  end

  describe "validation" do
    test "the four never-push events refuse push true", ctx do
      for type <- @never do
        assert errors(ctx.scope, %{"switches" => %{Atom.to_string(type) => true}}) == %{
                 type => ["never pushes"]
               }
      end

      # false is accepted and changes nothing.
      view = put_settings!(ctx.scope, %{"switches" => %{"task_assigned" => false}})
      refute Map.has_key?(view.switches, :task_assigned)
      assert Repo.all(Preference) == []
    end

    test "quiet start equal to end is refused", ctx do
      assert %{quiet_end: ["can't be the same as the start"]} =
               errors(ctx.scope, %{"quiet_start" => "08:00", "quiet_end" => "08:00"})

      # Only the start sent, equal to the stored end.
      assert %{quiet_end: ["can't be the same as the start"]} =
               errors(ctx.scope, %{"quiet_start" => "07:00"})

      # A refused first change creates no row.
      assert row(ctx.user) == nil
    end

    test "quiet hours spanning midnight are accepted, to the minute", ctx do
      view =
        put_settings!(ctx.scope, %{
          "quiet_hours_enabled" => true,
          "time_zone" => "Europe/London",
          "quiet_start" => "23:30:45",
          "quiet_end" => "00:15"
        })

      assert %{quiet_hours_enabled: true, quiet_start: ~T[23:30:00], quiet_end: ~T[00:15:00]} =
               view

      assert %PushSettings{quiet_start: ~T[23:30:00], quiet_end: ~T[00:15:00]} = row(ctx.user)
    end

    test "quiet times are HH:MM or HH:MM:SS, never an offset, a signed hour or a map", ctx do
      for time <- [
            "22:00:00+05:00",
            "22:00Z",
            "T22:00",
            "+7:05",
            "-0:30",
            "7:05",
            "24:00",
            "22:00:00.5",
            %{"hour" => 22, "minute" => 30},
            2200
          ] do
        assert errors(ctx.scope, %{"quiet_start" => time}) == %{quiet_start: ["is invalid"]},
               "#{inspect(time)} was not refused"
      end

      assert put_settings!(ctx.scope, %{"quiet_end" => "06:45"}).quiet_end == ~T[06:45:00]
    end

    test "quiet hours cannot be turned on without a time zone", ctx do
      assert errors(ctx.scope, %{"quiet_hours_enabled" => true}) == %{
               quiet_hours_enabled: ["needs a time zone"]
             }

      assert row(ctx.user) == nil

      view =
        put_settings!(ctx.scope, %{"quiet_hours_enabled" => true, "time_zone" => "Asia/Tokyo"})

      assert %{quiet_hours_enabled: true, time_zone: "Asia/Tokyo"} = view
    end

    test "a time zone sent as null, empty or blank is refused with or without a stored zone",
         ctx do
      for zone <- [nil, "", "   "] do
        assert errors(ctx.scope, %{"time_zone" => zone, "quiet_start" => "09:00"}) == %{
                 time_zone: ["is not a known time zone"]
               }
      end

      assert row(ctx.user) == nil
    end

    test "a switch sent as null or empty is refused, with or without a mode", ctx do
      for value <- [nil, ""] do
        assert errors(ctx.scope, %{"switches" => %{"mentioned" => value}}) == %{
                 mentioned: ["is invalid"]
               }

        assert errors(ctx.scope, %{
                 "mode" => "every",
                 "switches" => %{"task_reviewed" => true, "review_requested" => value}
               }) == %{review_requested: ["is invalid"]}
      end

      assert row(ctx.user) == nil
    end

    test "an unknown time zone is refused", ctx do
      for zone <- ["Mars/Base", " Europe/London", "europe/london", 42] do
        assert %{time_zone: [_message]} = errors(ctx.scope, %{"time_zone" => zone})
      end

      assert put_settings!(ctx.scope, %{"time_zone" => "America/New_York"}).time_zone ==
               "America/New_York"

      # Once set, a zone cannot be cleared.
      for zone <- [nil, ""] do
        assert %{time_zone: ["is not a known time zone"]} =
                 errors(ctx.scope, %{"time_zone" => zone})
      end
    end

    test "a switches value that is not an object, or a switch that is not a boolean, is refused",
         ctx do
      assert %{switches: ["is invalid"]} = errors(ctx.scope, %{"switches" => ["mentioned"]})

      assert %{mentioned: ["is invalid"]} =
               errors(ctx.scope, %{"switches" => %{"mentioned" => "x"}})
    end

    test "unknown keys and unknown switches are ignored", ctx do
      view = put_settings!(ctx.scope, %{"user_id" => 0, "switches" => %{"nope" => true}})
      assert view == Notifications.get_push_settings(ctx.scope)
    end

    test "settings belong to the scope's user only", ctx do
      other = user_fixture()
      put_settings!(ctx.scope, %{"mode" => "every", "time_zone" => "Asia/Tokyo"})

      assert row(other) == nil

      other_view = other |> user_scope_fixture() |> Notifications.get_push_settings()
      refute other_view.switches.mentioned
    end
  end

  describe "the device making the change" do
    test "a device revoked, or a user disabled, before the change commits changes nothing",
         ctx do
      device = device_fixture(ctx.scope, %{time_zone: "Europe/London"})
      {:ok, _revoked} = Kanban.Devices.revoke_device(ctx.scope, device)

      assert Notifications.update_push_settings(ctx.scope, %{"mode" => "every"},
               via: :ios,
               feature: :mobile_app,
               device: device
             ) == {:error, :revoked}

      live = device_fixture(ctx.scope, %{time_zone: "Europe/London"})

      Kanban.Accounts.User
      |> where([u], u.id == ^ctx.user.id)
      |> Repo.update_all(set: [disabled_at: DateTime.utc_now(:second)])

      assert Notifications.update_push_settings(ctx.scope, %{"mode" => "every"},
               via: :ios,
               feature: :mobile_app,
               device: live
             ) == {:error, :revoked}

      assert row(ctx.user).mode == :decisions
    end

    test "a live device's change is applied", ctx do
      device = device_fixture(ctx.scope, %{time_zone: "Europe/London"})

      assert {:ok, %{mode: :every}} =
               Notifications.update_push_settings(ctx.scope, %{"mode" => "every"},
                 via: :ios,
                 feature: :mobile_app,
                 device: device
               )
    end
  end

  describe "telemetry" do
    test "a change emits settings_changed with field names only; a no-op emits nothing", ctx do
      Kanban.TelemetryHelpers.attach_telemetry([:kanban, :push, :settings_changed])

      put_settings!(ctx.scope, %{"time_zone" => "Asia/Tokyo", "quiet_hours_enabled" => true})

      assert_received {:telemetry_event, [:kanban, :push, :settings_changed], %{count: 1},
                       metadata}

      assert metadata == %{
               mode: :decisions,
               fields: ["quiet_hours_enabled", "time_zone"],
               via: :ios
             }

      refute inspect(metadata) =~ "Tokyo"

      put_settings!(ctx.scope, %{"time_zone" => "Asia/Tokyo"})
      refute_received {:telemetry_event, _, _, _}

      put_settings!(ctx.scope, %{"mode" => "every"})
      assert_received {:telemetry_event, _, _, %{mode: :every, fields: fields}}
      assert fields == Enum.sort(["mode" | Enum.map(@updates, &Atom.to_string/1)])
    end

    test "a refused change emits nothing", ctx do
      Kanban.TelemetryHelpers.attach_telemetry([:kanban, :push, :settings_changed])
      errors(ctx.scope, %{"mode" => "every", "time_zone" => "Mars/Base"})
      refute_received {:telemetry_event, _, _, _}
      assert row(ctx.user) == nil
    end
  end

  describe "first device" do
    test "a device that reports its zone later fills an empty settings zone, never a set one",
         ctx do
      device = device_fixture(ctx.scope, %{time_zone: nil})
      assert row(ctx.user).time_zone == nil

      {:ok, _device} =
        Kanban.Devices.update_current(ctx.scope, device, %{"time_zone" => "Europe/Paris"})

      assert row(ctx.user).time_zone == "Europe/Paris"

      {:ok, _device} =
        Kanban.Devices.update_current(ctx.scope, device, %{"time_zone" => "Asia/Tokyo"})

      assert row(ctx.user).time_zone == "Europe/Paris"
    end

    test "first device creates the row with its time zone and a second device doesn't move it",
         ctx do
      device_fixture(ctx.scope, %{time_zone: "Europe/London"})
      assert %PushSettings{time_zone: "Europe/London", mode: :decisions} = row(ctx.user)

      device_fixture(ctx.scope, %{time_zone: "America/New_York"})
      assert row(ctx.user).time_zone == "Europe/London"
      assert Notifications.get_push_settings(ctx.scope).time_zone == "Europe/London"
    end

    test "a device leaves a zone set in settings alone", ctx do
      put_settings!(ctx.scope, %{"time_zone" => "Asia/Tokyo"})
      device_fixture(ctx.scope, %{time_zone: "Europe/London"})
      assert row(ctx.user).time_zone == "Asia/Tokyo"
    end

    test "a row without a zone takes the first device zone that arrives", ctx do
      device_fixture(ctx.scope, %{time_zone: nil})
      assert %PushSettings{time_zone: nil} = row(ctx.user)

      device_fixture(ctx.scope, %{time_zone: "Europe/Paris"})
      assert row(ctx.user).time_zone == "Europe/Paris"
    end

    test "a device that fails to insert creates no row", ctx do
      assert {:error, %Ecto.Changeset{}} =
               Kanban.Devices.create_device(ctx.scope, %{platform: :symbian}, DateTime.utc_now())

      assert row(ctx.user) == nil
    end
  end
end
