defmodule Mix.Tasks.Ios.Test do
  @shortdoc "Runs the iOS app's tests on a simulator and shows the results"

  @moduledoc """
  Generates the Xcode project and runs the iOS app's tests on a simulator,
  showing each test as it ends.

  It prints what is being built, every test's result, and any error or compiler
  warning. The complete `xcodebuild` output is in `mobile/ios/build/ios.test.log`.
  The task fails when `xcodebuild` fails, and also when no Swift Testing test
  ran, so a scheme that lost its tests does not pass. It needs a Mac with Xcode
  and XcodeGen.

  ## Usage

      mix ios.test
      mix ios.test StrideKitTests
      mix ios.test StrideKitTests/AuthStoreTests StrideUITests
      mix ios.test --simulator "iPad (A16)"
      mix ios.test --verbose
      mix ios.test -- -retry-tests-on-failure

  With no test names it runs the whole `Stride` scheme. A name is what
  `xcodebuild -only-testing:` takes: a test target, a suite in it, or a test in
  that. Anything after `--` is passed on to `xcodebuild`.

  ## Options

    * `--simulator` - the simulator's name or UDID, default `IOS_SIMULATOR` or
      an iPhone 17. Of several with the same name the newest iOS is used
    * `--verbose` - print every line of `xcodebuild` output
  """
  use Mix.Task

  alias Mix.Ios
  alias Mix.Ios.Output
  alias Mix.Ios.Simulator

  @switches [simulator: :string, verbose: :boolean]
  @log "mobile/ios/build/ios.test.log"

  @impl Mix.Task
  def run(args), do: test(args, [])

  @doc """
  Runs the tests, returning `:ok`, or raises `Mix.Error`. `opts` are the ones
  `Mix.Ios` describes.
  """
  @spec test([String.t()], keyword()) :: :ok
  def test(args, opts) do
    {own, extra} = Ios.split_args(args)
    {flags, only} = OptionParser.parse!(own, strict: @switches)

    Ios.generate_project!(opts)

    flags
    |> Simulator.from_flags!(opts)
    |> command(Enum.map(only, &"-only-testing:#{&1}") ++ extra)
    |> Output.xcodebuild(@log, flags[:verbose] || false, opts)
    |> report(only)
  end

  defp command(simulator, extra) do
    Mix.shell().info("Testing on #{Simulator.label(simulator)}")
    Ios.xcodebuild_args(["test"], Simulator.destination(simulator), extra)
  end

  defp report({output, 0}, only) do
    if ran?(output, only) do
      Mix.shell().info([
        :green,
        "iOS tests passed: #{output.swift_tests} in Swift Testing, #{output.xctests} in XCTest"
      ])
    else
      Mix.raise("xcodebuild passed but ran no #{missing(only)} tests. The output is in #{@log}")
    end
  end

  defp report({output, status}, _only) do
    shell = Mix.shell()
    shell.info("\nThe output ended with:")
    output |> Output.last_lines() |> Enum.each(&shell.info/1)

    shell.info("\nFailures:")
    output |> Output.failures() |> Enum.each(&shell.info([:red, &1]))

    Mix.raise("The iOS tests failed (xcodebuild exited #{status}). All the output is in #{@log}")
  end

  # The UI tests alone do not count as a run of the whole scheme.
  defp ran?(output, []), do: output.swift_tests > 0
  defp ran?(output, _only), do: output.swift_tests + output.xctests > 0

  defp missing([]), do: "Swift Testing"
  defp missing(only), do: Enum.join(only, " or ")
end
