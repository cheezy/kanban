defmodule Mix.Ios.Output do
  @moduledoc """
  Reads `xcodebuild` output one line at a time: `handle/2` prints the lines a
  person follows a build or a test run by, writes every line to a log, and
  counts the tests. A full run prints about 800 lines, mostly compiler calls.
  """

  alias Mix.Ios

  @enforce_keys [:log, :verbose?]
  defstruct @enforce_keys ++
              [targets: MapSet.new(), failures: [], swift_tests: 0, xctests: 0, last: []]

  @type t :: %__MODULE__{}

  @last_lines 40
  @max_failures 60

  @doc """
  Runs `xcodebuild` with its output handled here and logged to `log`, a path
  from the repository root. `verbose?` prints every line. Returns what was read
  and the exit status.
  """
  # The log path is a task's own constant.
  # sobelow_skip ["Traversal.FileModule"]
  @spec xcodebuild([String.t()], String.t(), boolean(), keyword()) :: {t(), non_neg_integer()}
  def xcodebuild(args, log, verbose?, opts) do
    path = opts |> Ios.root() |> Path.join(log)
    path |> Path.dirname() |> File.mkdir_p!()

    File.open!(path, [:write, :utf8], fn file ->
      Ios.stream("xcodebuild", args, %__MODULE__{log: file, verbose?: verbose?}, &handle/2, opts)
    end)
  end

  @doc "Handles one line of output."
  @spec handle(String.t(), t()) :: t()
  def handle(line, %__MODULE__{} = state) do
    # Swift Testing puts a zero-width space before some of its symbols.
    line = String.trim_leading(line, "\u200B")
    kind = classify(line)

    IO.puts(state.log, line)
    print(line, kind, state)

    %{state | last: Enum.take([line | state.last], @last_lines)}
    |> count(line)
    |> record(kind, line)
  end

  @doc """
  What a line is: a failure, a pass, a warning, a plain line worth showing, the
  start of a target's build, or none of these.
  """
  @spec classify(String.t()) ::
          :failure | :pass | :warning | :info | {:building, String.t()} | :hidden
  def classify(line) do
    Enum.find_value(patterns(), :hidden, fn {kind, pattern} ->
      case Regex.run(pattern, line) do
        nil -> nil
        [_, target] when kind == :building -> {:building, target}
        _ -> kind
      end
    end)
  end

  @doc "The failures seen, each once, in the order they were printed."
  @spec failures(t()) :: [String.t()]
  def failures(%__MODULE__{failures: failures}) do
    failures |> Enum.reverse() |> Enum.uniq() |> Enum.take(@max_failures)
  end

  @doc "The end of the output."
  @spec last_lines(t()) :: [String.t()]
  def last_lines(%__MODULE__{last: last}), do: Enum.reverse(last)

  defp patterns do
    [
      failure: ~r/^✘|^Test [Cc]ase '.+' failed|^\*\* .+ FAILED|^Testing failed:|(^|[:\s])error: /,
      pass: ~r/^✔|^Test [Cc]ase '.+' passed|^\*\* .+ SUCCEEDED/,
      warning: ~r/^\S+:\d+:\d+: warning: |^⚠/,
      info:
        ~r/^➜ |^↳ (?!Testing Library|Target Platform)|^Test [Cc]ase '.+' skipped|^Resolve Package/,
      building: ~r/^SwiftDriver (\S+) normal /
    ]
  end

  defp print(line, _kind, %{verbose?: true}), do: Mix.shell().info(line)
  defp print(_line, :hidden, _state), do: :ok

  defp print(_line, {:building, target}, state) do
    if target not in state.targets, do: Mix.shell().info("Building #{target}")
  end

  defp print(line, kind, _state), do: Mix.shell().info([color(kind), line])

  defp color(:failure), do: :red
  defp color(:pass), do: :green
  defp color(:warning), do: :yellow
  defp color(:info), do: :normal

  # Each test bundle prints its own total for Swift Testing.
  defp count(state, line) do
    case Regex.run(~r/Test run with (\d+) tests? /, line) do
      [_, tests] -> %{state | swift_tests: state.swift_tests + String.to_integer(tests)}
      nil -> count_xctest(state, line)
    end
  end

  defp count_xctest(state, line) do
    if line =~ ~r/^Test [Cc]ase '.+' (passed|failed)/,
      do: %{state | xctests: state.xctests + 1},
      else: state
  end

  defp record(state, :failure, line), do: %{state | failures: [line | state.failures]}

  defp record(state, {:building, target}, _line),
    do: %{state | targets: MapSet.put(state.targets, target)}

  defp record(state, _kind, _line), do: state
end
