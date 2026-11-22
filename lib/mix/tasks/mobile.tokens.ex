defmodule Mix.Tasks.Mobile.Tokens do
  @shortdoc "Generates the native apps' design tokens from app.css"

  @moduledoc """
  Writes `mobile/shared/tokens/tokens.json` (W2776): the `.stride-screen`
  colour, gradient, shadow, font, radius and type tokens in
  `assets/css/app.css`, for the light and the dark theme. The native apps read
  this file so they match the web in both themes without hand-copied colours.

  `Kanban.Mobile.Tokens` does the parsing and describes the file's shape.

  ## Usage

      MIX_ENV=test mix mobile.tokens

  It takes no arguments. Rerun it and commit the result whenever the
  `.stride-screen` tokens in `app.css` change:
  `test/kanban/mobile/tokens_test.exs` fails while the committed file is stale.
  Never edit the generated file by hand.
  """
  use Mix.Task

  alias Kanban.Mobile.Tokens

  @impl Mix.Task
  def run([]), do: generate([])

  def run(args) do
    Mix.raise(
      "mix mobile.tokens takes no arguments, got: #{Enum.join(args, " ")}. " <>
        "See mix help mobile.tokens."
    )
  end

  @doc """
  Renders the tokens and writes them, returning `:ok`.

  Options, which tests use to stay out of the repository:

    * `:source` - the stylesheet to read, default `assets/css/app.css`
    * `:output` - the file to write, default `mobile/shared/tokens/tokens.json`
  """
  @spec generate(keyword()) :: :ok
  def generate(opts) do
    source = Keyword.get(opts, :source, Tokens.source_path())
    output = Keyword.get(opts, :output, Tokens.output_path())

    json = source |> File.read!() |> Tokens.render!()
    output |> Path.dirname() |> File.mkdir_p!()
    File.write!(output, json)

    Mix.shell().info("Wrote #{output}")
  end
end
