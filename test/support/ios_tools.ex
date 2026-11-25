defmodule Kanban.IosTools do
  @moduledoc """
  Stub command-line tools for the tests of `mix ios.test` and `mix ios.deploy`:
  shell scripts that write their arguments to a file and print what the test
  asks for, so no test needs a Mac with Xcode.
  """

  @simulators %{
    "devices" => %{
      "com.apple.CoreSimulator.SimRuntime.iOS-26-4" => [
        %{"name" => "iPhone 17", "udid" => "OLD-17", "state" => "Booted"}
      ],
      "com.apple.CoreSimulator.SimRuntime.iOS-27-2" => [
        %{"name" => "iPhone 17", "udid" => "NEW-17", "state" => "Shutdown"},
        %{"name" => "iPad (A16)", "udid" => "NEW-IPAD", "state" => "Shutdown"}
      ],
      "com.apple.CoreSimulator.SimRuntime.watchOS-27-2" => [
        %{"name" => "Apple Watch", "udid" => "WATCH", "state" => "Shutdown"}
      ]
    }
  }

  @doc "The `devices` map simctl's stub lists."
  def simulators, do: @simulators["devices"]

  @doc """
  Writes the stubs to `dir` and returns the options that make the tasks use
  them. `bodies` maps a tool to the shell lines its stub runs instead of ending
  at once, or to `nil` for a tool that is not installed.
  """
  def stub_tools!(dir, bodies \\ %{}) do
    list = Path.join(dir, "simulators.json")
    File.write!(list, JSON.encode!(@simulators))

    bodies =
      Map.merge(
        %{
          "xcodegen" => "",
          "xcodebuild" => "",
          "xcrun" => ~s([ "$2" != list ] || { echo "a warning" >&2; cat "#{list}"; }),
          "xcode-select" => ~s(echo "#{dir}/Xcode/Developer"),
          "open" => ""
        },
        bodies
      )

    for {name, body} when is_binary(body) <- bodies, do: stub!(dir, name, body)

    [
      root: dir,
      find_executable: fn name -> if bodies[name], do: Path.join([dir, "bin", name]) end
    ]
  end

  @doc "The calls made to the stubs, one line each."
  def calls(dir) do
    case dir |> Path.join("calls") |> File.read() do
      {:ok, calls} -> String.split(calls, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  @doc "The last call made to the stubs."
  def last_call(dir), do: dir |> calls() |> List.last()

  @doc "Whether a call matching `pattern` was made to the stubs."
  def called?(dir, pattern), do: dir |> calls() |> Enum.any?(&(&1 =~ pattern))

  defp stub!(dir, name, body) do
    path = Path.join([dir, "bin", name])
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, "#!/bin/sh\necho \"#{name} $*\" >> \"#{dir}/calls\"\n#{body}\n")
    File.chmod!(path, 0o755)
  end
end
