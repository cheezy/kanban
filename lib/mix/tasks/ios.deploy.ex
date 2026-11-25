defmodule Mix.Tasks.Ios.Deploy do
  @shortdoc "Builds the iOS app and starts it on a simulator or a connected iPhone"

  @moduledoc """
  Generates the Xcode project, builds the iOS app, installs it and starts it: on
  a simulator, or with `--device` on an iPhone or iPad connected to this Mac.

  It boots the simulator when it is off. Pass `--open` to see it in Apple's
  simulator app, unless another window, such as Claude's simulator panel, shows
  it already. The complete `xcodebuild` output is in
  `mobile/ios/build/ios.deploy.log`. It needs a Mac with Xcode and XcodeGen. It
  does not upload to TestFlight or the App Store.

  ## Usage

      mix ios.deploy
      mix ios.deploy --open
      mix ios.deploy --simulator "iPad (A16)"
      DEVELOPMENT_TEAM=<team id> mix ios.deploy --device "My iPhone"
      DEVELOPMENT_TEAM=<team id> mix ios.deploy --device "My iPhone" -- -allowProvisioningUpdates

  Anything after `--` is passed on to `xcodebuild`.

  ## A connected device

  A build for a device must be signed. The repository holds no signing team, so
  the task reads the ten-character team id from `DEVELOPMENT_TEAM`. Keep it out
  of the repository. Add your Apple account to Xcode first, and turn on Developer
  Mode on the device. `-allowProvisioningUpdates` lets Xcode register the device
  and create what signing needs in your developer account, so it is passed only
  when you ask for it.

  ## Options

    * `--simulator` - the simulator's name or UDID, default `IOS_SIMULATOR` or
      an iPhone 17. Of several with the same name the newest iOS is used
    * `--device` - the connected device's name or UDID, as
      `xcrun devicectl list devices` shows it
    * `--open` - bring Apple's simulator app to the front
    * `--verbose` - print every line of `xcodebuild` output
  """
  use Mix.Task

  alias Mix.Ios
  alias Mix.Ios.Output
  alias Mix.Ios.Simulator

  @switches [simulator: :string, device: :string, open: :boolean, verbose: :boolean]
  @log "mobile/ios/build/ios.deploy.log"

  # Xcode 27 shows simulators in Device Hub; Xcode 26 and earlier in Simulator.
  @simulator_apps ["Applications/Simulator.app", "../Applications/DeviceHub.app"]

  @impl Mix.Task
  def run(args), do: deploy(args, [])

  @doc """
  Builds, installs and starts the app, returning `:ok`, or raises `Mix.Error`.
  `opts` are the ones `Mix.Ios` describes, and `:team` instead of
  `DEVELOPMENT_TEAM`.
  """
  @spec deploy([String.t()], keyword()) :: :ok
  def deploy(args, opts) do
    {own, extra} = Ios.split_args(args)

    case OptionParser.parse!(own, strict: @switches) do
      {flags, []} -> deploy_to(flags, extra, opts)
      {_, names} -> Mix.raise("mix ios.deploy does not take #{Enum.join(names, " ")}")
    end
  end

  defp deploy_to(flags, extra, opts) do
    case {flags[:simulator], flags[:device]} do
      {_, nil} -> deploy_to_simulator(flags, extra, opts)
      {nil, device} -> deploy_to_device(device, flags, extra, opts)
      _ -> Mix.raise("Pass --simulator or --device, not both")
    end
  end

  defp deploy_to_simulator(flags, extra, opts) do
    Ios.generate_project!(opts)
    simulator = Simulator.from_flags!(flags, opts)
    label = Simulator.label(simulator)
    app = build!(label, Simulator.destination(simulator), flags, extra, opts)

    xcrun!(["simctl", "bootstatus", simulator.udid, "-b"], opts)
    xcrun!(["simctl", "install", simulator.udid, app.path], opts)
    xcrun!(["simctl", "launch", "--terminate-running-process", simulator.udid, app.id], opts)
    if flags[:open], do: open_simulator_app(opts)

    started(app, label)
  end

  defp deploy_to_device(device, flags, extra, opts) do
    extra = ["DEVELOPMENT_TEAM=#{team!(opts)}" | extra]
    Ios.generate_project!(opts)
    app = build!(device, device_destination(device), flags, extra, opts)

    xcrun!(["devicectl", "device", "install", "app", "--device", device, app.path], opts)

    xcrun!(
      ["devicectl", "device", "process", "launch", "--terminate-existing"] ++
        ["--device", device, app.id],
      opts
    )

    started(app, device)
  end

  defp started(app, target), do: Mix.shell().info([:green, "Started #{app.id} on #{target}"])

  defp team!(opts) do
    team = Keyword.get_lazy(opts, :team, fn -> System.get_env("DEVELOPMENT_TEAM", "") end)

    if team =~ ~r/\A[A-Z0-9]{10}\z/ do
      team
    else
      Mix.raise(
        "A build for a device must be signed. Set DEVELOPMENT_TEAM to your ten-character " <>
          "Apple developer team id. See mix help ios.deploy."
      )
    end
  end

  # By its UDID, when that is what was given, or else by its name.
  defp device_destination(device) do
    key = if device =~ ~r/\A([0-9A-F]{8}-[0-9A-F]{16}|[0-9a-f]{40})\z/i, do: "id", else: "name"
    "platform=iOS,#{key}=#{device}"
  end

  defp build!(target, destination, flags, extra, opts) do
    Mix.shell().info("Building for #{target}")

    {output, status} =
      ["build"]
      |> Ios.xcodebuild_args(destination, extra)
      |> Output.xcodebuild(@log, flags[:verbose] || false, opts)

    if status != 0 do
      output |> Output.last_lines() |> Enum.each(fn line -> Mix.shell().info(line) end)
      Mix.raise("The build failed (xcodebuild exited #{status}). All the output is in #{@log}")
    end

    built_app!(destination, extra, opts)
  end

  # Xcode chooses the build folder, so ask it where the app is.
  defp built_app!(destination, extra, opts) do
    command = Ios.xcodebuild_args(["-showBuildSettings", "-json"], destination, extra)

    case Ios.capture("xcodebuild", command, [stderr: :discard] ++ opts) do
      {json, 0} -> json |> JSON.decode() |> app!()
      _ -> no_app!()
    end
  end

  defp app!({:ok, targets}) do
    case Enum.find(targets, &app?/1) do
      %{"buildSettings" => settings} -> app(settings)
      nil -> no_app!()
    end
  end

  defp app!({:error, _}), do: no_app!()

  defp no_app!,
    do: Mix.raise("The app was built, but xcodebuild did not say where it put it")

  defp app(%{
         "PRODUCT_BUNDLE_IDENTIFIER" => id,
         "TARGET_BUILD_DIR" => folder,
         "WRAPPER_NAME" => name
       }),
       do: %{id: id, path: Path.join(folder, name)}

  defp app?(%{"buildSettings" => %{"WRAPPER_EXTENSION" => "app"}}), do: true
  defp app?(_), do: false

  defp xcrun!(args, opts) do
    {output, status} = Ios.capture("xcrun", args, opts)

    if status != 0 do
      Mix.raise("xcrun #{Enum.join(args, " ")} failed:\n" <> String.trim(output))
    end
  end

  # Only a convenience: the app is already running, so nothing here may fail.
  defp open_simulator_app(opts) do
    with {developer, 0} <- Ios.capture("xcode-select", ["-p"], opts),
         app when is_binary(app) <- simulator_app(String.trim(developer)) do
      Ios.capture("open", [app], opts)
    end

    :ok
  end

  defp simulator_app(developer) do
    @simulator_apps |> Enum.map(&Path.expand(&1, developer)) |> Enum.find(&File.exists?/1)
  end
end
