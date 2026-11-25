defmodule Mix.Tasks.Ios.TestTest do
  # async: false — swaps the process-wide Mix shell.
  use ExUnit.Case, async: false

  import Kanban.IosTools

  @moduletag :tmp_dir

  @task Mix.Tasks.Ios.Test
  @simulator ["--simulator", "iPhone 17"]
  @log "mobile/ios/build/ios.test.log"

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)
    :ok
  end

  test "generates the project and tests the whole scheme", %{tmp_dir: dir} do
    opts = passing(dir)
    assert @task.test(@simulator, opts) == :ok

    assert calls(dir) == [
             "xcodegen generate --quiet --spec mobile/ios/project.yml",
             "xcrun simctl list devices available -j",
             "xcodebuild test -project mobile/ios/Stride.xcodeproj -scheme Stride " <>
               "-skipPackagePluginValidation -destination platform=iOS Simulator,id=NEW-17"
           ]

    assert_received {:mix_shell, :info, ["Testing on iPhone 17 (iOS 27.2)"]}
    assert_received {:mix_shell, :info, ["✔ Test run with 12 tests in 3 suites passed"]}

    assert_received {:mix_shell, :info, ["iOS tests passed: 12 in Swift Testing, 1 in XCTest"]}

    assert dir |> Path.join(@log) |> File.read!() =~ "cd /x\n"
    refute_received {:mix_shell, :info, ["cd /x"]}
  end

  test "prints everything with --verbose", %{tmp_dir: dir} do
    opts = passing(dir)
    assert @task.test(["--verbose" | @simulator], opts) == :ok
    assert_received {:mix_shell, :info, ["cd /x"]}
  end

  test "runs only the tests named, and passes on what follows --", %{tmp_dir: dir} do
    args = ["StrideKitTests/AuthStoreTests", "StrideUITests"] ++ @simulator ++ ["--", "-quiet"]

    opts = passing(dir)
    assert @task.test(args, opts) == :ok

    assert last_call(dir) =~
             ~r/-only-testing:StrideKitTests\/AuthStoreTests -only-testing:StrideUITests -quiet$/
  end

  test "fails when xcodebuild does, naming the failures and the log", %{tmp_dir: dir} do
    opts = stub_tools!(dir, %{"xcodebuild" => "echo 'V.swift:3:1: error: no type'; exit 65"})

    assert_raise Mix.Error, ~r/exited 65.*#{@log}/, fn -> @task.test(@simulator, opts) end

    # As it is printed, at the end of the output, and in the list of failures.
    for _ <- 1..3 do
      assert_received {:mix_shell, :info, ["V.swift:3:1: error: no type"]}
    end
  end

  test "fails when no Swift Testing test ran", %{tmp_dir: dir} do
    for line <- ["** TEST SUCCEEDED **", "Test run with 0 tests in 0 suites passed", xctest()] do
      opts = stub_tools!(dir, %{"xcodebuild" => "cat <<'EOF'\n#{line}\nEOF"})

      assert_raise Mix.Error, ~r/ran no Swift Testing tests/, fn ->
        @task.test(@simulator, opts)
      end
    end
  end

  test "lets the named tests be XCTest ones, but not none", %{tmp_dir: dir} do
    opts = stub_tools!(dir, %{"xcodebuild" => "cat <<'EOF'\n#{xctest()}\nEOF"})
    assert @task.test(["StrideUITests" | @simulator], opts) == :ok

    opts = stub_tools!(dir)

    assert_raise Mix.Error, ~r/ran no Nope tests/, fn ->
      @task.test(["Nope" | @simulator], opts)
    end
  end

  test "fails before the build when the project or the simulator is not there", %{tmp_dir: dir} do
    opts = stub_tools!(dir, %{"xcodegen" => "exit 1"})
    assert_raise Mix.Error, ~r/xcodegen/, fn -> @task.test(@simulator, opts) end

    opts = stub_tools!(dir)

    assert_raise Mix.Error, ~r/No simulator is named iPod/, fn ->
      @task.test(["--simulator", "iPod"], opts)
    end

    refute called?(dir, "xcodebuild")
  end

  test "refuses an unknown option before it runs anything", %{tmp_dir: dir} do
    opts = stub_tools!(dir)
    assert_raise OptionParser.ParseError, fn -> @task.test(["--nope"], opts) end
    assert calls(dir) == []
  end

  test "run/1 takes the task's arguments" do
    assert_raise OptionParser.ParseError, fn -> @task.run(["--nope"]) end
  end

  defp passing(dir) do
    stub_tools!(dir, %{
      "xcodebuild" => """
      cat <<'EOF'
      cd /x
      ✔ Test run with 12 tests in 3 suites passed
      #{xctest()}
      EOF
      """
    })
  end

  defp xctest, do: "Test Case '-[StrideUITests.LaunchUITests testLaunches]' passed (7.0 seconds)."
end
