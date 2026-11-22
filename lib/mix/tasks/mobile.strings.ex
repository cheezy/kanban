defmodule Mix.Tasks.Mobile.Strings do
  @shortdoc "Generates the native apps' strings from the mobile gettext domain"

  @moduledoc """
  Writes `mobile/shared/strings/<locale>.json` (W2777) for de, en, es, fr, ja,
  pt and zh from the `mobile` gettext domain in `priv/gettext`. The native apps
  read these files so their text is translated in the same pass as the web's.

  `Kanban.Mobile.Strings` holds the strings and describes the files' shape.

  ## Usage

      MIX_ENV=test mix mobile.strings

  It takes no arguments. After changing a string in `Kanban.Mobile.Strings`,
  run `MIX_ENV=test mix gettext.extract --merge`, translate it in every locale,
  then rerun this task and commit the result:
  `test/kanban/mobile/strings_test.exs` fails while a committed file is stale.
  Never edit the generated files by hand.
  """
  use Mix.Task

  alias Kanban.Mobile.Strings

  @impl Mix.Task
  def run([]), do: generate([])

  def run(args) do
    Mix.raise(
      "mix mobile.strings takes no arguments, got: #{Enum.join(args, " ")}. " <>
        "See mix help mobile.strings."
    )
  end

  @doc """
  Renders every locale's strings and writes one file per locale, returning
  `:ok`.

  Options, which tests use to stay out of the repository:

    * `:source` - the gettext directory to read, default `priv/gettext`
    * `:output` - the folder to write, default `mobile/shared/strings`
  """
  @spec generate(keyword()) :: :ok
  def generate(opts) do
    source = Keyword.get(opts, :source, Strings.source_path())
    output = Keyword.get(opts, :output, Strings.output_dir())

    rendered = Strings.render!(source)
    File.mkdir_p!(output)

    for {locale, json} <- Enum.sort(rendered) do
      path = Path.join(output, locale <> ".json")
      File.write!(path, json)
      Mix.shell().info("Wrote #{path}")
    end

    :ok
  end
end
