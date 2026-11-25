defmodule Mix.Tasks.Mobile.Api do
  @shortdoc "Checks the API contract and writes the copies both apps build from"

  @moduledoc """
  Writes the copies of the API contract `priv/openapi/stride-api.json` that the
  native apps generate their API clients from:

    * `mobile/shared/openapi.json` (W2779), which keeps the contract's exact bytes
    * `mobile/ios/StrideKit/Sources/StrideKit/openapi.json` (W2783), which
      `Kanban.Mobile.SwiftContract.derive!/1` derives for the Swift generator

  It first checks the contract with
  `Kanban.Mobile.ApiContract.validate/1`: it must parse, every operation needs
  a unique `operationId`, and every `/api/me` operation needs `deviceAuth` and a
  response schema for each 2xx response with a body (a `204` has none). A
  contract that breaks a rule is not copied.

  Generating the Swift and Kotlin clients belongs to each app's own build, not
  to this task.

  ## Usage

      MIX_ENV=test mix mobile.api

  It takes no arguments. Rerun it and commit the result whenever the contract
  changes: `test/kanban/mobile/api_contract_test.exs` and
  `test/kanban/mobile/swift_contract_test.exs` fail while a committed copy is
  stale. Never edit a copy by hand.
  """
  use Mix.Task

  alias Kanban.Mobile.ApiContract
  alias Kanban.Mobile.SwiftContract

  @impl Mix.Task
  def run([]), do: generate([])

  def run(args) do
    Mix.raise(
      "mix mobile.api takes no arguments, got: #{Enum.join(args, " ")}. " <>
        "See mix help mobile.api."
    )
  end

  @doc """
  Checks the contract and writes both copies, returning `:ok`. Raises
  `ArgumentError` listing every problem, without writing, when the contract
  is invalid.

  Options, which tests use to stay out of the repository:

    * `:source` - the contract to read, default `priv/openapi/stride-api.json`
    * `:output` - the exact copy to write, default `mobile/shared/openapi.json`
    * `:swift_output` - the Swift document to write, default
      `mobile/ios/StrideKit/Sources/StrideKit/openapi.json`
  """
  @spec generate(keyword()) :: :ok
  def generate(opts) do
    source = Keyword.get(opts, :source, ApiContract.source_path())
    output = Keyword.get(opts, :output, ApiContract.output_path())

    swift_output = Keyword.get(opts, :swift_output, SwiftContract.output_path())

    json = source |> File.read!() |> ApiContract.validate_source!()
    swift_json = SwiftContract.derive!(json)

    write!(output, json)
    write!(swift_output, swift_json)
  end

  defp write!(path, contents) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, contents)

    Mix.shell().info("Wrote #{path}")
  end
end
