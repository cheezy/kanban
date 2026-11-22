defmodule Mix.Tasks.Mobile.Api do
  @shortdoc "Checks the API contract and copies it to mobile/shared/openapi.json"

  @moduledoc """
  Writes `mobile/shared/openapi.json` (W2779), the copy of the API contract
  `priv/openapi/stride-api.json` that both native apps generate their API
  clients from. It first checks the contract with
  `Kanban.Mobile.ApiContract.validate/1`: it must parse, every operation needs
  a unique `operationId`, and every `/api/me` operation needs `deviceAuth` and a
  response schema for each 2xx response with a body (a `204` has none). A
  contract that breaks a rule is not copied.

  The copy keeps the contract's exact bytes. Generating the Swift and Kotlin
  clients from it belongs to each app's own build, not to this task.

  ## Usage

      MIX_ENV=test mix mobile.api

  It takes no arguments. Rerun it and commit the result whenever the contract
  changes: `test/kanban/mobile/api_contract_test.exs` fails while the committed
  copy is stale. Never edit the copy by hand.
  """
  use Mix.Task

  alias Kanban.Mobile.ApiContract

  @impl Mix.Task
  def run([]), do: generate([])

  def run(args) do
    Mix.raise(
      "mix mobile.api takes no arguments, got: #{Enum.join(args, " ")}. " <>
        "See mix help mobile.api."
    )
  end

  @doc """
  Checks the contract and writes the copy, returning `:ok`. Raises
  `ArgumentError` listing every problem, without writing, when the contract
  is invalid.

  Options, which tests use to stay out of the repository:

    * `:source` - the contract to read, default `priv/openapi/stride-api.json`
    * `:output` - the file to write, default `mobile/shared/openapi.json`
  """
  @spec generate(keyword()) :: :ok
  def generate(opts) do
    source = Keyword.get(opts, :source, ApiContract.source_path())
    output = Keyword.get(opts, :output, ApiContract.output_path())

    json = source |> File.read!() |> ApiContract.validate_source!()
    output |> Path.dirname() |> File.mkdir_p!()
    File.write!(output, json)

    Mix.shell().info("Wrote #{output}")
  end
end
