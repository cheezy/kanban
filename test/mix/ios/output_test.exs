defmodule Mix.Ios.OutputTest do
  # async: false — swaps the process-wide Mix shell.
  use ExUnit.Case, async: false

  import Kanban.IosTools

  alias Mix.Ios.Output

  @moduletag :tmp_dir

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)
    :ok
  end

  # Lines as xcodebuild prints them, from Swift Testing, XCTest and the compiler.
  @lines [
    {"✔ Test \"links\" passed after 0.001 seconds.", :pass},
    {"✔ Suite SmokeTests passed after 0.006 seconds.", :pass},
    {"Test Case '-[StrideUITests.LaunchUITests testLaunches]' passed (7.090 seconds).", :pass},
    {"Test case 'LaunchUITests.testLaunches()' passed on 'Clone 1' (7.0 seconds)", :pass},
    {"** TEST SUCCEEDED **", :pass},
    {"✘ Test \"links\" recorded an issue at SmokeTests.swift:9:9: Expectation failed", :failure},
    {"Test Case '-[StrideUITests.LaunchUITests testLaunches]' failed (7.0 seconds).", :failure},
    {"** TEST FAILED **", :failure},
    {"Testing failed:", :failure},
    {"/x/View.swift:3:1: error: no such type", :failure},
    {"xcodebuild: error: Unable to find a device", :failure},
    {"error: the package could not be resolved", :failure},
    {"/x/View.swift:3:1: warning: never used", :warning},
    {"⚠︎ a warning issue", :warning},
    {"↳ the pair must be equal", :info},
    {"➜ Test \"links\" skipped.", :info},
    {"Test Case '-[StrideUITests.LaunchUITests testLaunches]' skipped (0.1 seconds).", :info},
    {"Resolve Package Graph", :info},
    {"SwiftDriver Stride normal arm64 com.apple.xcode.tools.swift.compiler (in target)",
     {:building, "Stride"}},
    {"SwiftDriver\\ Compilation Stride normal arm64 com.apple.xcode", :hidden},
    {"◇ Test \"links\" started.", :hidden},
    {"↳ Testing Library Version: 2403", :hidden},
    {"↳ Target Platform: arm64-apple-ios17.0-simulator", :hidden},
    {"        ➜ Explicit dependency on target 'StrideKit'", :hidden},
    {"appintentsmetadataprocessor[1:2] warning: Metadata extraction skipped", :hidden},
    {"    t =     0.10s Set Up", :hidden},
    {"", :hidden}
  ]

  test "classify/1 tells results, errors and warnings from compiler calls" do
    for {line, kind} <- @lines do
      assert {line, Output.classify(line)} == {line, kind}
    end
  end

  describe "handle/2" do
    test "prints the lines worth showing and logs every line", %{tmp_dir: dir} do
      run(dir, ["\u200B✔ Test \"a\" passed", "cd /x", "x: error: no"])

      assert printed() == ["✔ Test \"a\" passed", "x: error: no"]
      assert logged(dir, "log") == "✔ Test \"a\" passed\ncd /x\nx: error: no\n"
    end

    test "names each target once as its build starts", %{tmp_dir: dir} do
      run(dir, [
        "SwiftDriver Stride normal arm64",
        "SwiftDriver Stride normal x86_64",
        "SwiftDriver StrideKit normal arm64"
      ])

      assert printed() == ["Building Stride", "Building StrideKit"]
    end

    test "prints every line as it is when verbose", %{tmp_dir: dir} do
      run(dir, ["cd /x", "SwiftDriver Stride normal arm64"], true)

      assert printed() == ["cd /x", "SwiftDriver Stride normal arm64"]
    end

    test "counts the tests of every bundle", %{tmp_dir: dir} do
      output =
        run(dir, [
          "✔ Test run with 14 tests in 5 suites passed after 0.1 seconds.",
          "Test Case '-[A b]' passed (1.0 seconds).",
          "Test Case '-[A c]' failed (1.0 seconds).",
          "Test Case '-[A d]' skipped (1.0 seconds).",
          "✘ Test run with 1 test in 1 suite failed after 0.1 seconds with 1 issue."
        ])

      assert output.swift_tests == 15
      assert output.xctests == 2
    end

    test "keeps each failure once, and the end of the output", %{tmp_dir: dir} do
      output = run(dir, Enum.map(1..100, &"line #{&1}") ++ ["a: error: x", "✘ b", "a: error: x"])
      last_lines = Output.last_lines(output)

      assert Output.failures(output) == ["a: error: x", "✘ b"]
      assert length(last_lines) == 40
      assert hd(last_lines) == "line 64"
      assert Enum.take(last_lines, -2) == ["✘ b", "a: error: x"]
    end
  end

  test "xcodebuild/4 runs xcodebuild and writes the log, in a new folder", %{tmp_dir: dir} do
    opts = stub_tools!(dir, %{"xcodebuild" => "echo '✔ Test run with 3 tests passed'; exit 65"})

    assert {%Output{swift_tests: 3}, 65} = Output.xcodebuild(["test"], "a/b.log", false, opts)
    assert calls(dir) == ["xcodebuild test"]
    assert logged(dir, "a/b.log") == "✔ Test run with 3 tests passed\n"
  end

  defp run(dir, lines, verbose? \\ false) do
    path = Path.join(dir, "log")

    File.open!(path, [:write, :utf8], fn file ->
      Enum.reduce(lines, %Output{log: file, verbose?: verbose?}, &Output.handle/2)
    end)
  end

  defp logged(dir, log), do: dir |> Path.join(log) |> File.read!()

  defp printed do
    receive do
      {:mix_shell, :info, [line]} -> [line | printed()]
    after
      0 -> []
    end
  end
end
