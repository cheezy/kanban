defmodule Mix.Tasks.Ios.DeployTest do
  # async: false — swaps the process-wide Mix shell.
  use ExUnit.Case, async: false

  import Kanban.IosTools

  @moduletag :tmp_dir

  @task Mix.Tasks.Ios.Deploy
  @simulator ["--simulator", "iPhone 17"]
  @team "ABCDE12345"
  @udid "00008150-000A1B2C3D4E5F60"
  @scheme "-project mobile/ios/Stride.xcodeproj -scheme Stride -skipPackagePluginValidation"

  @settings JSON.encode!([
              %{"buildSettings" => %{"WRAPPER_EXTENSION" => "appex"}},
              %{
                "buildSettings" => %{
                  "WRAPPER_EXTENSION" => "app",
                  "WRAPPER_NAME" => "Stride.app",
                  "TARGET_BUILD_DIR" => "/build/Debug",
                  "PRODUCT_BUNDLE_IDENTIFIER" => "com.example.stride"
                }
              }
            ])

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)
    :ok
  end

  describe "to a simulator" do
    test "builds the app, boots the simulator, installs the app and starts it", %{tmp_dir: dir} do
      opts = built(dir)
      assert @task.deploy(@simulator, opts) == :ok

      destination = "-destination platform=iOS Simulator,id=NEW-17"

      assert calls(dir) == [
               "xcodegen generate --quiet --spec mobile/ios/project.yml",
               "xcrun simctl list devices available -j",
               "xcodebuild build #{@scheme} #{destination}",
               "xcodebuild -showBuildSettings -json #{@scheme} #{destination}",
               "xcrun simctl bootstatus NEW-17 -b",
               "xcrun simctl install NEW-17 /build/Debug/Stride.app",
               "xcrun simctl launch --terminate-running-process NEW-17 com.example.stride"
             ]

      assert_received {:mix_shell, :info, ["Building for iPhone 17 (iOS 27.2)"]}

      assert_received {:mix_shell, :info, ["Started com.example.stride on iPhone 17 (iOS 27.2)"]}

      assert dir |> Path.join("mobile/ios/build/ios.deploy.log") |> File.exists?()
    end

    test "opens whichever simulator app this Xcode has with --open", %{tmp_dir: dir} do
      opts = built(dir)
      hub = Path.join(dir, "Xcode/Applications/DeviceHub.app")
      File.mkdir_p!(hub)

      assert @task.deploy(["--open" | @simulator], opts) == :ok
      assert last_call(dir) == "open #{hub}"

      simulator = Path.join(dir, "Xcode/Developer/Applications/Simulator.app")
      File.mkdir_p!(simulator)

      assert @task.deploy(["--open" | @simulator], opts) == :ok
      assert last_call(dir) == "open #{simulator}"
    end

    test "succeeds when there is no simulator app to open", %{tmp_dir: dir} do
      for select <- ["echo /no/such/folder", "exit 2"] do
        opts = built(dir, %{"xcode-select" => select})

        assert @task.deploy(["--open" | @simulator], opts) == :ok
        assert last_call(dir) == "xcode-select -p"
      end
    end

    test "passes on what follows -- to the build and to the look-up", %{tmp_dir: dir} do
      args = @simulator ++ ["--", "-configuration", "Release"]

      opts = built(dir)

      assert @task.deploy(args, opts) == :ok
      assert called?(dir, ~r/^xcodebuild build .* -configuration Release$/)
      assert called?(dir, ~r/^xcodebuild -showBuildSettings .* -configuration Release$/)
    end

    test "stops when the build fails, with the end of its output", %{tmp_dir: dir} do
      opts = stub_tools!(dir, %{"xcodebuild" => "echo 'it broke'; exit 65"})

      assert_raise Mix.Error, ~r/The build failed \(xcodebuild exited 65\)/, fn ->
        @task.deploy(@simulator, opts)
      end

      assert_received {:mix_shell, :info, ["it broke"]}
      refute called?(dir, "install")
    end

    test "stops when xcodebuild does not say where the app is", %{tmp_dir: dir} do
      for settings <- ["nonsense", "[]", ~s([{"buildSettings": {}}])] do
        opts = stub_tools!(dir, %{"xcodebuild" => "echo '#{settings}'"})

        assert_raise Mix.Error, ~r/did not say where/, fn -> @task.deploy(@simulator, opts) end
      end
    end

    test "stops at the first simctl step that fails, with its output", %{tmp_dir: dir} do
      for {step, later} <- [{"bootstatus", "install"}, {"install", "launch"}, {"launch", "open"}] do
        dir |> Path.join("calls") |> File.rm()
        opts = failing_simctl(dir, step)

        assert_raise Mix.Error, ~r/simctl #{step} .* failed:\nno #{step}/, fn ->
          @task.deploy(["--open" | @simulator], opts)
        end

        refute called?(dir, ~r/^(open|xcrun simctl #{later})/)
      end
    end
  end

  describe "to a connected device" do
    test "builds with the team, installs the app and starts it", %{tmp_dir: dir} do
      opts = [team: @team] ++ built(dir)
      assert @task.deploy(["--device", "My iPhone"], opts) == :ok

      build = "#{@scheme} -destination platform=iOS,name=My iPhone DEVELOPMENT_TEAM=#{@team}"

      assert calls(dir) == [
               "xcodegen generate --quiet --spec mobile/ios/project.yml",
               "xcodebuild build #{build}",
               "xcodebuild -showBuildSettings -json #{build}",
               "xcrun devicectl device install app --device My iPhone /build/Debug/Stride.app",
               "xcrun devicectl device process launch --terminate-existing " <>
                 "--device My iPhone com.example.stride"
             ]

      assert_received {:mix_shell, :info, ["Started com.example.stride on My iPhone"]}
    end

    test "finds the device by its UDID when that is given", %{tmp_dir: dir} do
      opts = [team: @team] ++ built(dir)

      assert @task.deploy(["--device", @udid], opts) == :ok
      assert called?(dir, "xcodebuild build #{@scheme} -destination platform=iOS,id=#{@udid} ")
    end

    test "registers nothing with Apple unless asked to", %{tmp_dir: dir} do
      opts = [team: @team] ++ built(dir)

      assert @task.deploy(["--device", "My iPhone"], opts) == :ok
      refute called?(dir, "-allowProvisioningUpdates")

      args = ["--device", "My iPhone", "--", "-allowProvisioningUpdates"]
      assert @task.deploy(args, opts) == :ok
      assert called?(dir, ~r/^xcodebuild build .* -allowProvisioningUpdates$/)
    end

    test "needs a team id, and does not repeat a wrong one", %{tmp_dir: dir} do
      for team <- ["", "abcde12345", "ABCDE12345 ", "ABCDE12345\nX=1", "ABC"] do
        opts = [team: team] ++ built(dir)

        error =
          assert_raise Mix.Error, ~r/Set DEVELOPMENT_TEAM/, fn ->
            @task.deploy(["--device", "My iPhone"], opts)
          end

        if team != "", do: refute(error.message =~ team)
      end

      assert calls(dir) == []
    end
  end

  test "refuses a device with a simulator, a name, or an unknown option", %{tmp_dir: dir} do
    opts = stub_tools!(dir)

    assert_raise Mix.Error, ~r/not both/, fn ->
      @task.deploy(["--device", "My iPhone" | @simulator], opts)
    end

    assert_raise Mix.Error, ~r/does not take iPhone/, fn -> @task.deploy(["iPhone"], opts) end
    assert_raise OptionParser.ParseError, fn -> @task.deploy(["--nope"], opts) end
    assert_raise OptionParser.ParseError, fn -> @task.run(["--nope"]) end
    assert calls(dir) == []
  end

  defp built(dir, bodies \\ %{}) do
    xcodebuild = ~s([ "$1" = build ] || echo '#{@settings}')
    stub_tools!(dir, Map.merge(%{"xcodebuild" => xcodebuild}, bodies))
  end

  defp failing_simctl(dir, step) do
    list = Path.join(dir, "simulators.json")

    built(dir, %{
      "xcrun" => """
      [ "$2" != list ] || cat "#{list}"
      [ "$2" != #{step} ] || { echo "no #{step}" >&2; exit 1; }
      """
    })
  end
end
