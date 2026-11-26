defmodule Mix.Tasks.Mobile.Tokens do
  @shortdoc "Generates the native apps' design tokens from app.css"

  @moduledoc """
  Writes `mobile/shared/tokens/tokens.json` (W2776): the `.stride-screen`
  colour, gradient, shadow, font, radius and type tokens in
  `assets/css/app.css`, for the light and the dark theme. The native apps read
  this file so they match the web in both themes without hand-copied colours.

  It also writes the iOS app's colour asset catalog,
  `mobile/ios/Stride/DesignSystem/Colors.xcassets`, with a light and a dark
  value for every colour token, and its other tokens as Swift constants in
  `mobile/ios/Stride/DesignSystem/DesignTokens.swift` (W2787). A colour set in
  the catalog that is no longer a token is removed.

  `Kanban.Mobile.Tokens` does the parsing and describes the file's shape.
  `Kanban.Mobile.IosDesignSystem` describes the iOS files.

  ## Usage

      MIX_ENV=test mix mobile.tokens

  It takes no arguments. Rerun it and commit the result whenever the
  `.stride-screen` tokens in `app.css` change:
  `test/kanban/mobile/tokens_test.exs` and
  `test/kanban/mobile/ios_design_system_test.exs` fail while a committed file
  is stale. Never edit the generated files by hand.
  """
  use Mix.Task

  alias Kanban.Mobile.IosDesignSystem
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
  Renders the tokens and the iOS files and writes them, returning `:ok`.

  Options, which tests use to stay out of the repository:

    * `:source` - the stylesheet to read, default `assets/css/app.css`
    * `:output` - the file to write, default `mobile/shared/tokens/tokens.json`
    * `:root` - the folder the iOS files' paths start from, default the
      project root
  """
  @spec generate(keyword()) :: :ok
  def generate(opts) do
    css = opts |> Keyword.get(:source, Tokens.source_path()) |> File.read!()
    root = Keyword.get(opts, :root, "")

    # Everything is rendered before anything is written.
    json = Tokens.render!(css)
    tokens = Tokens.build!(css)
    ios_files = IosDesignSystem.render!(tokens)

    opts |> Keyword.get(:output, Tokens.output_path()) |> write!(json)
    write_ios!(root, tokens, ios_files)
  end

  defp write_ios!(root, tokens, ios_files) do
    for {path, content} <- Enum.sort(ios_files),
        do: root |> Path.join(path) |> write_file!(content)

    catalog = Path.join(root, IosDesignSystem.catalog_dir())
    count = tokens |> IosDesignSystem.colorset_names() |> length()
    Mix.shell().info("Wrote #{catalog} with #{count} colour sets")
    Mix.shell().info("Wrote #{Path.join(root, IosDesignSystem.swift_path())}")

    remove_stale_colorsets!(catalog, tokens)
  end

  defp remove_stale_colorsets!(catalog, tokens) do
    keep = IosDesignSystem.colorset_names(tokens)

    for name <- File.ls!(catalog), Path.extname(name) == ".colorset", name not in keep do
      path = Path.join(catalog, name)
      File.rm_rf!(path)
      Mix.shell().info("Removed #{path}")
    end

    :ok
  end

  defp write!(path, content) do
    write_file!(path, content)
    Mix.shell().info("Wrote #{path}")
  end

  defp write_file!(path, content) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, content)
  end
end
