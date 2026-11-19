defmodule KanbanWeb.API.Me.NotificationSettingsControllerTest do
  @moduledoc """
  Tests for `GET` and `PUT /api/me/notification_settings`
  (`KanbanWeb.API.Me.NotificationSettingsController`), W2767.
  """
  # async: false - some tests switch the global :plans_enforced application env on.
  use KanbanWeb.ConnCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.DevicesFixtures
  import Kanban.PlansHelpers
  import Kanban.TelemetryHelpers

  alias Kanban.ApiTokens

  @path "/api/me/notification_settings"
  @plan_required %{
    "error" => "plan_required",
    "feature" => "mobile_app",
    "message" => "The Stride app is available to boards in an Organization."
  }

  setup do
    user = user_fixture()
    scope = user_scope_fixture(user)
    {_device, phone} = device_with_tokens_fixture(scope, %{time_zone: "Europe/London"})

    {_device, tablet} =
      device_with_tokens_fixture(scope, %{
        platform: :android,
        device_class: :tablet,
        time_zone: "Asia/Tokyo"
      })

    %{user: user, scope: scope, phone: phone.access_token, tablet: tablet.access_token}
  end

  defp authed(token) do
    put_req_header(build_conn(), "authorization", "Bearer " <> token)
  end

  defp show(token), do: token |> authed() |> get(@path)
  defp put_settings(token, body), do: token |> authed() |> put(@path, body)

  describe "GET /api/me/notification_settings" do
    test "GET returns mode, switches, quiet hours and time zone", ctx do
      assert show(ctx.phone) |> json_response(200) == %{
               "data" => %{
                 "mode" => "decisions",
                 "switches" => %{
                   "review_requested" => true,
                   "task_unclaimed" => true,
                   "claim_expired" => true,
                   "after_goal_failed" => true,
                   "task_reviewed" => false,
                   "goal_completed" => false,
                   "target_status_changed" => false,
                   "mentioned" => false
                 },
                 "quiet_hours_enabled" => false,
                 "quiet_start" => "22:00",
                 "quiet_end" => "07:00",
                 # The first device's zone; the second device did not move it.
                 "time_zone" => "Europe/London"
               }
             }
    end
  end

  describe "PUT /api/me/notification_settings" do
    test "PUT changes one switch and emits settings_changed with its field name", ctx do
      attach_telemetry([:kanban, :push, :settings_changed])

      assert %{"data" => data} =
               ctx.phone
               |> put_settings(%{"switches" => %{"task_reviewed" => true}})
               |> json_response(200)

      assert data["switches"]["task_reviewed"]
      assert data["mode"] == "decisions"
      assert show(ctx.phone) |> json_response(200) == %{"data" => data}

      assert_received {:telemetry_event, [:kanban, :push, :settings_changed], %{count: 1},
                       %{mode: :decisions, fields: ["task_reviewed"], via: :ios}}

      # The tablet reports itself; the time zone is named, never sent.
      assert ctx.tablet |> put_settings(%{"time_zone" => "America/Chicago"}) |> json_response(200)
      assert_received {:telemetry_event, _, _, %{fields: ["time_zone"], via: :android} = metadata}
      refute inspect(metadata) =~ "Chicago"

      # Sending what is already stored changes nothing and emits nothing.
      assert ctx.phone |> put_settings(%{"time_zone" => "America/Chicago"}) |> json_response(200)
      refute_received {:telemetry_event, _, _, _}
    end

    # The shared sandbox runs both requests on one connection, so this checks
    # that two devices' changes each land; the lost-update race itself is
    # proven by test/kanban/notifications/push_settings_race_test.exs.
    test "two PUTs at once both persist without losing a field", ctx do
      bodies = [
        {ctx.phone, %{"quiet_hours_enabled" => true}},
        {ctx.tablet, %{"switches" => %{"mentioned" => true}, "time_zone" => "America/New_York"}}
      ]

      statuses =
        bodies
        |> Enum.map(fn {token, body} ->
          Elixir.Task.async(fn -> put_settings(token, body).status end)
        end)
        |> Enum.map(&Elixir.Task.await(&1, 10_000))

      assert statuses == [200, 200]

      assert %{
               "quiet_hours_enabled" => true,
               "time_zone" => "America/New_York",
               "switches" => %{"mentioned" => true, "review_requested" => true}
             } = show(ctx.phone) |> json_response(200) |> Map.fetch!("data")
    end

    test "a mode sets its preset, then each switch can change", ctx do
      assert %{"data" => %{"mode" => "every", "switches" => switches}} =
               ctx.phone |> put_settings(%{"mode" => "every"}) |> json_response(200)

      assert switches |> Map.values() |> Enum.all?()

      assert %{"data" => %{"mode" => "every", "switches" => %{"mentioned" => false}}} =
               ctx.phone
               |> put_settings(%{"switches" => %{"mentioned" => false}})
               |> json_response(200)
    end

    test "an invalid change is 422 with the fields and messages, never the values", ctx do
      body = %{
        "time_zone" => "Mars/Base",
        "quiet_start" => "10:00",
        "quiet_end" => "10:00",
        "switches" => %{"comment_added" => true}
      }

      assert ctx.phone |> put_settings(body) |> json_response(422) == %{
               "errors" => %{
                 "time_zone" => ["is not a known time zone"],
                 "quiet_end" => ["can't be the same as the start"],
                 "comment_added" => ["never pushes"]
               }
             }

      assert show(ctx.phone) |> json_response(200) |> get_in(["data", "time_zone"]) ==
               "Europe/London"
    end

    test "keys the app may not change are ignored", ctx do
      other = user_fixture()

      assert %{"data" => data} =
               ctx.phone
               |> put_settings(%{
                 "user_id" => other.id,
                 "last_summary_at" => "2026-01-01T00:00:00Z"
               })
               |> json_response(200)

      assert data == show(ctx.phone) |> json_response(200) |> Map.fetch!("data")
      refute Kanban.Repo.get(Kanban.Notifications.PushSettings, other.id)

      assert Kanban.Repo.get(Kanban.Notifications.PushSettings, ctx.user.id).last_summary_at ==
               nil
    end

    test "matches the documented schemas", ctx do
      spec = KanbanWeb.API.OpenApiSpec.path() |> File.read!() |> Jason.decode!()

      data = show(ctx.phone) |> json_response(200) |> Map.fetch!("data")
      assert_schema(spec, data, "NotificationSettings")
      assert_schema(spec, data["switches"], "PushSwitches")

      updated =
        ctx.phone
        |> put_settings(%{"mode" => "every", "quiet_hours_enabled" => true})
        |> json_response(200)

      assert_schema(spec, updated, "NotificationSettingsResponse")
      assert_schema(spec, updated["data"], "NotificationSettings")

      invalid = ctx.phone |> put_settings(%{"mode" => "all"}) |> json_response(422)
      assert_schema(spec, invalid, "ValidationError")
    end
  end

  describe "plan gating" do
    test "plan_required when the person has no paid access", ctx do
      enforce_plans()

      assert show(ctx.phone) |> json_response(403) == @plan_required

      assert ctx.phone |> put_settings(%{"mode" => "every"}) |> json_response(403) ==
               @plan_required

      refute Kanban.Repo.get(Kanban.Notifications.PushSettings, ctx.user.id).mode == :every
    end

    test "the context refuses a crafted change from a user without paid access", ctx do
      enforce_plans()

      assert Kanban.Notifications.update_push_settings(ctx.scope, %{"mode" => "every"},
               via: :ios,
               feature: :mobile_app
             ) == {:error, {:plan_required, :mobile_app}}

      assert Kanban.Repo.get(Kanban.Notifications.PushSettings, ctx.user.id).mode == :decisions
    end
  end

  describe "authentication" do
    test "an agent API token or an unknown token gets 401", ctx do
      {:ok, {_api_token, agent_token}} =
        ApiTokens.create_api_token(ctx.user, ai_optimized_board_fixture(ctx.user), %{
          name: "Agent"
        })

      for token <- [agent_token, "not-a-device-token"] do
        assert token |> show() |> json_response(401)
        assert token |> put_settings(%{"mode" => "every"}) |> json_response(401)
      end
    end

    test "a device revoked after its token was accepted gets 401 and changes nothing", ctx do
      device =
        Kanban.Repo.get_by!(Kanban.Devices.Device, user_id: ctx.user.id, platform: :ios)

      # The pipeline has already admitted the device; it is revoked before the
      # action runs, as a revocation in flight would be.
      {:ok, _revoked} = Kanban.Devices.revoke_device(ctx.scope, device)

      conn =
        :put
        |> build_conn(@path, %{"mode" => "every"})
        |> assign(:current_scope, ctx.scope)
        |> assign(:current_device, device)
        |> KanbanWeb.API.Me.NotificationSettingsController.call(:update)

      assert json_response(conn, 401) == %{"error" => "Invalid access token"}
      assert Kanban.Repo.get(Kanban.Notifications.PushSettings, ctx.user.id).mode == :decisions
    end

    test "a request with no token gets 401" do
      assert build_conn() |> get(@path) |> json_response(401)
      assert build_conn() |> put(@path, %{}) |> json_response(401)
    end
  end

  # Every required key is rendered and every rendered key is documented.
  defp assert_schema(spec, value, schema) do
    %{"properties" => properties, "required" => required} = spec["components"]["schemas"][schema]
    assert_keys(value, required, properties, schema)

    for {key, rendered} <- value do
      assert type_allowed?(rendered, properties[key]),
             "#{schema}.#{key} is #{inspect(rendered)}, not #{inspect(properties[key])}"
    end
  end

  defp assert_keys(value, required, properties, schema) do
    keys = value |> Map.keys() |> MapSet.new()
    documented = properties |> Map.keys() |> MapSet.new()

    assert required |> MapSet.new() |> MapSet.subset?(keys), "#{schema} is missing a required key"
    assert MapSet.subset?(keys, documented), "#{schema} does not document every rendered key"
  end

  # A property with a $ref is checked by its own schema.
  defp type_allowed?(_value, %{"$ref" => _}), do: true

  defp type_allowed?(value, %{"type" => types} = property) do
    types |> List.wrap() |> Enum.any?(&json_type?(value, &1)) and
      in_enum?(value, property) and matches_pattern?(value, property)
  end

  defp in_enum?(value, %{"enum" => values}), do: value in values
  defp in_enum?(_value, _property), do: true

  defp matches_pattern?(value, %{"pattern" => pattern}), do: value =~ Regex.compile!(pattern)
  defp matches_pattern?(_value, _property), do: true

  defp json_type?(nil, "null"), do: true
  defp json_type?(value, "string"), do: is_binary(value)
  defp json_type?(value, "integer"), do: is_integer(value)
  defp json_type?(value, "boolean"), do: is_boolean(value)
  defp json_type?(value, "array"), do: is_list(value)
  defp json_type?(value, "object"), do: is_map(value)
  defp json_type?(_value, _type), do: false
end
