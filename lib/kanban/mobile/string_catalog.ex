defmodule Kanban.Mobile.StringCatalog do
  @moduledoc """
  Builds the iOS app's string catalog from the `mobile` gettext domain (W2785,
  W2788). `mix mobile.strings` writes it to
  `mobile/ios/Stride/Resources/Localizable.xcstrings`.

  The catalog holds the same keys and text as
  `mobile/shared/strings/<locale>.json`, in the form iOS reads:

    * A `{name}` placeholder becomes a positional specifier, numbered by where it
      first appears in the English text, so a translation can put the arguments
      in another order. `{count}` and `{done}` are integers (`%1$lld`), every
      other placeholder is text (`%1$@`). A literal `%` in a string with a
      placeholder becomes `%%`.
    * A plural varies by `count`, with the categories of the shared file: `one`
      and `other`, or `other` alone for ja and zh. A plural whose only
      placeholder is `{count}` varies as a whole; one with more arguments, such
      as `target_task_progress`, varies through a `count` substitution.
    * The `zh` locale is `zh-Hans`, the name iOS uses for simplified Chinese.

  Every entry is marked `manual`, so Xcode neither marks it as unused nor changes
  it, and generates a Swift symbol for it: `target_status_on_track` is
  `LocalizedStringResource.targetStatusOnTrack`, and a string with arguments is a
  function of them, such as `.targetGoalCount(3)`.

  `test/kanban/mobile/string_catalog_test.exs` fails while the committed catalog
  is stale. Refresh it with `MIX_ENV=test mix mobile.strings`, and never edit it
  by hand or in Xcode.
  """
  alias Jason.OrderedObject
  alias Kanban.Mobile.Strings

  @output_path "mobile/ios/Stride/Resources/Localizable.xcstrings"
  @source_locale "en"
  @ios_locales %{"zh" => "zh-Hans"}
  @integer_arguments ~w(count done)
  @plural_argument "count"
  @placeholder ~r/\{(\w+)\}/

  @doc "The catalog, relative to the project root."
  @spec output_path() :: String.t()
  def output_path, do: @output_path

  @doc """
  The name iOS gives a shared locale.

      iex> Kanban.Mobile.StringCatalog.ios_locale("zh")
      "zh-Hans"
      iex> Kanban.Mobile.StringCatalog.ios_locale("de")
      "de"
  """
  @spec ios_locale(String.t()) :: String.t()
  def ios_locale(locale), do: Map.get(@ios_locales, locale, locale)

  @doc """
  Renders the catalog from what `Kanban.Mobile.Strings.build!/1` returns: pretty
  JSON, keys sorted, ending in a newline.
  """
  @spec render(%{String.t() => Strings.locale_strings()}) :: String.t()
  def render(strings_by_locale) do
    entries =
      strings_by_locale
      |> singular_entries()
      |> Map.merge(plural_entries(strings_by_locale))

    catalog =
      sorted(%{
        "sourceLanguage" => @source_locale,
        "strings" => sorted(entries),
        "version" => "1.0"
      })

    Jason.encode!(catalog, pretty: true) <> "\n"
  end

  defp singular_entries(strings_by_locale) do
    for {key, text} <- strings_by_locale[@source_locale]["strings"], into: %{} do
      {key, entry(strings_by_locale, &string_localization(&1["strings"][key], arguments(text)))}
    end
  end

  defp plural_entries(strings_by_locale) do
    plurals = Map.get(strings_by_locale[@source_locale], "plurals", %{})

    for {key, %{"other" => text}} <- plurals, into: %{} do
      {key, entry(strings_by_locale, &plural_localization(&1["plurals"][key], arguments(text)))}
    end
  end

  @doc """
  Turns a shared string's `{name}` placeholders into the positional specifiers
  of `arguments`, the placeholder names in the order the English text names
  them. Text without arguments is returned unchanged.

      iex> Kanban.Mobile.StringCatalog.format("{b} after {a}", ["a", "b"])
      "%2$@ after %1$@"
  """
  @spec format(String.t(), [String.t()]) :: String.t()
  def format(text, []), do: text

  def format(text, arguments) do
    text
    |> String.replace("%", "%%")
    |> then(&Regex.replace(@placeholder, &1, fn _match, name -> specifier(name, arguments) end))
  end

  defp specifier(name, arguments) do
    position = Enum.find_index(arguments, &(&1 == name)) + 1
    "%#{position}$#{type(name)}"
  end

  defp type(name), do: if(integer?(name), do: "lld", else: "@")

  @doc "Whether the placeholder `name` takes an integer rather than text."
  @spec integer?(String.t()) :: boolean()
  def integer?(name), do: name in @integer_arguments

  @doc """
  The names of the `{name}` placeholders in `text`, in the order they first
  appear: the order of the catalog's positional arguments.

      iex> Kanban.Mobile.StringCatalog.arguments("{done} of {count}, {done}")
      ["done", "count"]
  """
  @spec arguments(String.t()) :: [String.t()]
  def arguments(text) do
    @placeholder |> Regex.scan(text, capture: :all_but_first) |> List.flatten() |> Enum.uniq()
  end

  defp entry(strings_by_locale, localization) do
    localizations =
      Map.new(strings_by_locale, fn {locale, strings} ->
        {ios_locale(locale), localization.(strings)}
      end)

    sorted(%{"extractionState" => "manual", "localizations" => sorted(localizations)})
  end

  defp string_localization(text, arguments),
    do: sorted(%{"stringUnit" => unit(format(text, arguments))})

  defp plural_localization(forms, [@plural_argument] = arguments) do
    sorted(%{"variations" => variations(forms, arguments)})
  end

  defp plural_localization(forms, arguments) do
    substitution =
      sorted(%{
        "argNum" => Enum.find_index(arguments, &(&1 == @plural_argument)) + 1,
        "formatSpecifier" => type(@plural_argument),
        "variations" => variations(forms, arguments)
      })

    sorted(%{
      "stringUnit" => unit("%#@#{@plural_argument}@"),
      "substitutions" => sorted(%{@plural_argument => substitution})
    })
  end

  defp variations(forms, arguments) do
    plural =
      Map.new(forms, fn {category, text} ->
        {category, sorted(%{"stringUnit" => unit(format(text, arguments))})}
      end)

    sorted(%{"plural" => sorted(plural)})
  end

  defp unit(value), do: sorted(%{"state" => "translated", "value" => value})

  defp sorted(map), do: %OrderedObject{values: Enum.sort(map)}
end
