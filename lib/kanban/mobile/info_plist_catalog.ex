defmodule Kanban.Mobile.InfoPlistCatalog do
  @moduledoc """
  Builds the iOS app's Info.plist string catalog from the `mobile` gettext
  domain (W2798). `mix mobile.strings` writes it to
  `mobile/ios/Stride/Resources/InfoPlist.xcstrings`, which Xcode turns into each
  locale's `InfoPlist.strings`.

  iOS shows some Info.plist values to the person, such as the reason it gives
  when the app first asks for Face ID (`NSFaceIDUsageDescription`). Each of
  those keys is named in `keys/0` with the `mobile` string that holds its text,
  and the English text is also the key's value in `mobile/ios/project.yml`, as
  `INFOPLIST_KEY_<key>`, since iOS reads a key only when the Info.plist has it.

  The text takes no placeholders: iOS shows it as it is. `render/1` raises
  `ArgumentError` when a string is missing or holds a placeholder.

  `test/kanban/mobile/info_plist_catalog_test.exs` fails while the committed
  catalog or the value in `project.yml` is stale. Refresh the catalog with
  `MIX_ENV=test mix mobile.strings`, and never edit it by hand or in Xcode.
  """
  alias Jason.OrderedObject
  alias Kanban.Mobile.StringCatalog
  alias Kanban.Mobile.Strings

  @output_path "mobile/ios/Stride/Resources/InfoPlist.xcstrings"
  @source_locale "en"
  @keys %{"NSFaceIDUsageDescription" => "info_plist_face_id_usage"}

  @doc "The catalog, relative to the project root."
  @spec output_path() :: String.t()
  def output_path, do: @output_path

  @doc "Each Info.plist key the catalog translates, with its `mobile` string's key."
  @spec keys() :: %{String.t() => String.t()}
  def keys, do: @keys

  @doc """
  Renders the catalog from what `Kanban.Mobile.Strings.build!/1` returns: pretty
  JSON, keys sorted, ending in a newline.
  """
  @spec render(%{String.t() => Strings.locale_strings()}) :: String.t()
  def render(strings_by_locale) do
    entries =
      Map.new(@keys, fn {plist_key, key} -> {plist_key, entry(strings_by_locale, key)} end)

    catalog =
      sorted(%{
        "sourceLanguage" => @source_locale,
        "strings" => sorted(entries),
        "version" => "1.0"
      })

    Jason.encode!(catalog, pretty: true) <> "\n"
  end

  defp entry(strings_by_locale, key) do
    localizations =
      Map.new(strings_by_locale, fn {locale, strings} ->
        {StringCatalog.ios_locale(locale), localization(text!(strings, locale, key))}
      end)

    sorted(%{"extractionState" => "manual", "localizations" => sorted(localizations)})
  end

  defp text!(strings, locale, key),
    do: strings |> get_in(["strings", key]) |> checked!(locale, key)

  defp checked!(nil, locale, key),
    do: raise(ArgumentError, "#{locale} has no mobile string #{key} for the Info.plist")

  defp checked!(text, locale, key) do
    if StringCatalog.arguments(text) == [] do
      text
    else
      raise ArgumentError,
            "#{locale} #{key} holds a placeholder, which the Info.plist cannot fill"
    end
  end

  defp localization(text),
    do: sorted(%{"stringUnit" => sorted(%{"state" => "translated", "value" => text})})

  defp sorted(map), do: %OrderedObject{values: Enum.sort(map)}
end
