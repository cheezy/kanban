defmodule Kanban.Mobile.StringCatalog do
  @moduledoc """
  Builds the iOS app's string catalog from the `mobile` gettext domain (W2785).
  `mix mobile.strings` writes it to
  `mobile/ios/Stride/Resources/Localizable.xcstrings`.

  The catalog holds the same keys and text as
  `mobile/shared/strings/<locale>.json`, with two differences:

    * Plurals and strings with a placeholder are left out. The app has no screen
      that shows one yet.
    * The `zh` locale is `zh-Hans`, the name iOS uses for simplified Chinese.

  Every entry is marked `manual`, so Xcode neither marks it as unused nor changes
  it, and generates a Swift symbol for it: `target_status_on_track` is
  `LocalizedStringResource.targetStatusOnTrack`.

  `test/kanban/mobile/string_catalog_test.exs` fails while the committed catalog
  is stale. Refresh it with `MIX_ENV=test mix mobile.strings`, and never edit it
  by hand or in Xcode.
  """
  alias Jason.OrderedObject
  alias Kanban.Mobile.Strings

  @output_path "mobile/ios/Stride/Resources/Localizable.xcstrings"
  @source_locale "en"
  @ios_locales %{"zh" => "zh-Hans"}

  @doc "The catalog, relative to the project root."
  @spec output_path() :: String.t()
  def output_path, do: @output_path

  @doc """
  Renders the catalog from what `Kanban.Mobile.Strings.build!/1` returns: pretty
  JSON, keys sorted, ending in a newline.
  """
  @spec render(%{String.t() => Strings.locale_strings()}) :: String.t()
  def render(strings_by_locale) do
    keys = for {key, text} <- strings_by_locale[@source_locale]["strings"], plain?(text), do: key

    catalog =
      sorted(%{
        "sourceLanguage" => @source_locale,
        "strings" => keys |> Map.new(&{&1, entry(&1, strings_by_locale)}) |> sorted(),
        "version" => "1.0"
      })

    Jason.encode!(catalog, pretty: true) <> "\n"
  end

  # Strings.build!/1 lets a brace through only as part of a placeholder.
  defp plain?(text), do: !String.contains?(text, "{")

  defp entry(key, strings_by_locale) do
    localizations =
      Map.new(strings_by_locale, fn {locale, %{"strings" => strings}} ->
        unit = sorted(%{"state" => "translated", "value" => strings[key]})
        {Map.get(@ios_locales, locale, locale), sorted(%{"stringUnit" => unit})}
      end)

    sorted(%{"extractionState" => "manual", "localizations" => sorted(localizations)})
  end

  defp sorted(map), do: %OrderedObject{values: Enum.sort(map)}
end
