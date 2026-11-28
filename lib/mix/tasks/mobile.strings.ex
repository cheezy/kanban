defmodule Mix.Tasks.Mobile.Strings do
  @shortdoc "Generates the native apps' strings from the mobile gettext domain"

  @moduledoc """
  Writes `mobile/shared/strings/<locale>.json` (W2777) for de, en, es, fr, ja,
  pt and zh from the `mobile` gettext domain in `priv/gettext`, the iOS app's
  string catalog, `mobile/ios/Stride/Resources/Localizable.xcstrings` (W2785),
  its typed accessors, `mobile/ios/Stride/DesignSystem/L10n.swift` (W2788), and
  its Info.plist strings, `mobile/ios/Stride/Resources/InfoPlist.xcstrings`
  (W2798). The
  native apps read these files so their text is translated in the same pass as the
  web's.

  `Kanban.Mobile.Strings` holds the strings and describes the files' shape.
  `Kanban.Mobile.StringCatalog` describes the catalog,
  `Kanban.Mobile.StringAccessors` the accessors and
  `Kanban.Mobile.InfoPlistCatalog` the Info.plist strings.

  ## Usage

      MIX_ENV=test mix mobile.strings

  It takes no arguments. After changing a string in `Kanban.Mobile.Strings`,
  run `MIX_ENV=test mix gettext.extract --merge`, translate it in every locale,
  then rerun this task and commit the result:
  `test/kanban/mobile/strings_test.exs`,
  `test/kanban/mobile/string_catalog_test.exs`,
  `test/kanban/mobile/string_accessors_test.exs` and
  `test/kanban/mobile/info_plist_catalog_test.exs` fail while a committed file
  is stale.
  Never edit the generated files by hand.
  """
  use Mix.Task

  alias Kanban.Mobile.InfoPlistCatalog
  alias Kanban.Mobile.StringAccessors
  alias Kanban.Mobile.StringCatalog
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
  Renders every locale's strings and writes one file per locale, the iOS
  string catalog, its accessors and the Info.plist strings, returning `:ok`.

  Options, which tests use to stay out of the repository:

    * `:source` - the gettext directory to read, default `priv/gettext`
    * `:output` - the folder to write, default `mobile/shared/strings`
    * `:catalog` - the string catalog to write, default
      `mobile/ios/Stride/Resources/Localizable.xcstrings`
    * `:accessors` - the accessors to write, default
      `mobile/ios/Stride/DesignSystem/L10n.swift`
    * `:info_plist` - the Info.plist strings to write, default
      `mobile/ios/Stride/Resources/InfoPlist.xcstrings`
  """
  @spec generate(keyword()) :: :ok
  def generate(opts) do
    source = Keyword.get(opts, :source, Strings.source_path())

    # Everything is rendered before anything is written.
    rendered = Strings.render!(source)
    strings = Strings.build!(source)
    catalog = StringCatalog.render(strings)
    accessors = StringAccessors.render(strings)
    info_plist = InfoPlistCatalog.render(strings)

    opts |> Keyword.get(:output, Strings.output_dir()) |> write_locales!(rendered)
    opts |> Keyword.get(:catalog, StringCatalog.output_path()) |> write!(catalog)
    opts |> Keyword.get(:accessors, StringAccessors.output_path()) |> write!(accessors)
    opts |> Keyword.get(:info_plist, InfoPlistCatalog.output_path()) |> write!(info_plist)
  end

  defp write_locales!(output, rendered) do
    for {locale, json} <- Enum.sort(rendered) do
      output |> Path.join(locale <> ".json") |> write!(json)
    end
  end

  defp write!(path, content) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, content)
    Mix.shell().info("Wrote #{path}")
  end
end
