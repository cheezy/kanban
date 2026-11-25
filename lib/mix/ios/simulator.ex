defmodule Mix.Ios.Simulator do
  @moduledoc """
  Picks one simulator from `xcrun simctl list devices available -j` by its name
  or its UDID.
  """

  alias Mix.Ios

  @enforce_keys [:name, :udid, :version, :booted?]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          name: String.t(),
          udid: String.t(),
          version: {non_neg_integer(), non_neg_integer()},
          booted?: boolean()
        }

  @doc "Finds the simulator, or raises naming the ones this Mac has."
  @spec find!(String.t(), keyword()) :: t()
  def find!(wanted, opts) do
    args = ["simctl", "list", "devices", "available", "-j"]

    with {json, 0} <- Ios.capture("xcrun", args, Keyword.put(opts, :stderr, :discard)),
         {:ok, %{"devices" => devices}} <- JSON.decode(json) do
      simulators = parse(devices)
      pick(simulators, wanted) || not_found!(simulators, wanted)
    else
      _ -> Mix.raise("xcrun simctl could not list the simulators. Is Xcode set up?")
    end
  end

  @doc "The simulator that `--simulator` in `flags` names, or the default one."
  @spec from_flags!(keyword(), keyword()) :: t()
  def from_flags!(flags, opts) do
    flags |> Keyword.get_lazy(:simulator, &Ios.default_simulator/0) |> find!(opts)
  end

  @doc "The `xcodebuild` destination of a simulator."
  @spec destination(t()) :: String.t()
  def destination(%__MODULE__{udid: udid}), do: "platform=iOS Simulator,id=#{udid}"

  @doc "The name and iOS version, for people."
  @spec label(t()) :: String.t()
  def label(%__MODULE__{name: name, version: {major, minor}}),
    do: "#{name} (iOS #{major}.#{minor})"

  @doc "The simulators that run iOS, from the `devices` map of simctl's JSON."
  @spec parse(map()) :: [t()]
  def parse(devices) do
    for {runtime, simulators} <- devices,
        {_, _} = version <- [version(runtime)],
        simulator <- simulators do
      %__MODULE__{
        name: simulator["name"],
        udid: simulator["udid"],
        version: version,
        booted?: simulator["state"] == "Booted"
      }
    end
  end

  @doc """
  The simulator with this UDID or name. Of several with the same name it picks
  the newest iOS, as `xcodebuild` does, and then one that is booted.
  """
  @spec pick([t()], String.t()) :: t() | nil
  def pick(simulators, wanted) do
    Enum.find(simulators, &(&1.udid == String.upcase(wanted))) ||
      simulators
      |> Enum.filter(&(&1.name == wanted))
      |> Enum.max_by(&{&1.version, &1.booted?}, fn -> nil end)
  end

  # The iOS version a runtime's identifier ends in, or nil for another system.
  defp version(runtime) do
    case Regex.run(~r/\.iOS-(\d+)-(\d+)/, runtime) do
      [_, major, minor] -> {String.to_integer(major), String.to_integer(minor)}
      nil -> nil
    end
  end

  defp not_found!(simulators, wanted) do
    names = simulators |> Enum.map(& &1.name) |> Enum.uniq() |> Enum.sort() |> Enum.join(", ")

    Mix.raise(
      "No simulator is named #{wanted}. Pass --simulator or set IOS_SIMULATOR to one of: #{names}"
    )
  end
end
