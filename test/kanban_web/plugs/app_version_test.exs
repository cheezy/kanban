defmodule KanbanWeb.Plugs.AppVersionTest do
  # async: false - the tests change the global :mobile_min_versions app env.
  use KanbanWeb.ConnCase, async: false

  import Kanban.TelemetryHelpers

  alias Kanban.Devices.AppPolicy
  alias KanbanWeb.Plugs.AppVersion

  @refused [:kanban, :api, :outdated_app_refused]

  @min_versions %{
    ios: %{min_version: "2.1.0", store_url: "https://apps.apple.com/app/id-test"},
    android: %{min_version: "3.0.0", store_url: "https://play.google.com/store/apps/test"}
  }

  setup do
    previous = Application.fetch_env(:kanban, :mobile_min_versions)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:kanban, :mobile_min_versions, value)
        :error -> Application.delete_env(:kanban, :mobile_min_versions)
      end
    end)

    Application.put_env(:kanban, :mobile_min_versions, @min_versions)
    attach_telemetry(@refused)
    :ok
  end

  defp call_with(headers) do
    headers
    |> Enum.reduce(build_conn(), fn value, conn ->
      %{conn | req_headers: conn.req_headers ++ [{"x-stride-app", value}]}
    end)
    |> AppVersion.call([])
  end

  describe "call/2" do
    test "parses ios and android headers and answers 426 below the minimum" do
      ios = call_with(["ios/2.0.9 (42)"])

      assert ios.halted

      assert json_response(ios, 426) == %{
               "error" => "app_update_required",
               "store_url" => "https://apps.apple.com/app/id-test"
             }

      assert_received {:telemetry_event, @refused, %{count: 1}, %{platform: "ios"}}

      android = call_with(["android/2.99.99"])

      assert json_response(android, 426) == %{
               "error" => "app_update_required",
               "store_url" => "https://play.google.com/store/apps/test"
             }

      assert_received {:telemetry_event, @refused, %{count: 1}, %{platform: "android"}}
    end

    test "lets the minimum and anything above it through, ignoring the build number" do
      for header <- ["ios/2.1.0 (1)", "ios/2.1.0", "ios/2.1.1 (7)", "ios/10.0.0", "android/3.0.0"] do
        conn = call_with([header])
        refute conn.halted, "expected #{header} to pass"
        assert is_nil(conn.status)
      end

      refute_received {:telemetry_event, @refused, _measurements, _metadata}
    end

    test "lets a request with no, unparseable, unknown-platform or repeated headers through" do
      long = "ios/1.0.0 (" <> String.duplicate("9", 80) <> ")"

      cases = [
        [],
        ["ios/1.0"],
        ["ios/01.0.0"],
        ["iOS/1.0.0"],
        ["web/1.0.0"],
        ["windows/0.0.1 (1)"],
        [" ios/1.0.0"],
        ["ios/1.0.0-beta"],
        [long],
        ["ios/1.0.0", "ios/1.0.0"]
      ]

      for headers <- cases do
        refute call_with(headers).halted, "expected #{inspect(headers)} to pass"
      end

      refute_received {:telemetry_event, @refused, _measurements, _metadata}
    end

    test "a configured minimum that does not parse falls back to the default" do
      Application.put_env(:kanban, :mobile_min_versions, %{
        ios: %{min_version: "not-a-version", store_url: ""}
      })

      assert AppPolicy.min_versions().ios == %{
               min_version: "1.0.0",
               store_url: "https://apps.apple.com/app/stride"
             }

      refute call_with(["ios/1.0.0"]).halted
      assert json_response(call_with(["ios/0.9.0"]), 426)["store_url"] =~ "apps.apple.com"
    end
  end

  describe "Kanban.Devices.AppPolicy" do
    test "parse_header/1 returns the platform and version, never an atom from input" do
      assert {:ok, :ios, %Version{major: 1, minor: 2, patch: 3}} =
               AppPolicy.parse_header("ios/1.2.3 (42)")

      assert {:ok, :android, %Version{major: 0, minor: 0, patch: 1}} =
               AppPolicy.parse_header("android/0.0.1")

      for bad <- [nil, 42, "", "ios", "ios/", "ios/1.2.3 ()", "ios/1.2.3 (x)", "ios/1.2.3(42)"] do
        assert AppPolicy.parse_header(bad) == :error, "expected #{inspect(bad)} to be :error"
      end
    end

    test "min_versions/0 keeps the defaults for a platform the config leaves out" do
      Application.put_env(:kanban, :mobile_min_versions, %{android: %{min_version: "4.0.0"}})

      assert AppPolicy.min_versions() == %{
               ios: %{min_version: "1.0.0", store_url: "https://apps.apple.com/app/stride"},
               android: %{
                 min_version: "4.0.0",
                 store_url:
                   "https://play.google.com/store/apps/details?id=com.stridelikeaboss.app"
               }
             }

      Application.put_env(:kanban, :mobile_min_versions, :not_a_map)
      assert AppPolicy.min_versions().android.min_version == "1.0.0"
    end

    test "config/runtime.exs sets a minimum only from the variables that are set" do
      runtime = Path.expand("../../../config/runtime.exs", __DIR__)

      vars =
        ~w(STRIDE_IOS_MIN_VERSION STRIDE_IOS_STORE_URL STRIDE_ANDROID_MIN_VERSION STRIDE_ANDROID_STORE_URL)

      saved = Map.new(vars, &{&1, System.get_env(&1)})

      on_exit(fn ->
        for {name, value} <- saved do
          if value, do: System.put_env(name, value), else: System.delete_env(name)
        end
      end)

      read = fn ->
        runtime
        |> Config.Reader.read!(env: :test, target: :host)
        |> get_in([:kanban, :mobile_min_versions])
      end

      Enum.each(vars, &System.delete_env/1)
      assert read.() == %{}

      System.put_env("STRIDE_IOS_MIN_VERSION", "2.0.0")
      System.put_env("STRIDE_ANDROID_STORE_URL", "")
      assert read.() == %{ios: %{min_version: "2.0.0"}}
    end

    test "phone_limits/0 and platforms/0" do
      assert AppPolicy.phone_limits() == %{phone_max_files: 10, phone_max_lines: 500}
      assert AppPolicy.platforms() == [:ios, :android]
    end
  end
end
