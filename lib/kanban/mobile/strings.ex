defmodule Kanban.Mobile.Strings do
  @moduledoc """
  Holds the `mobile` gettext domain the native apps read (W2777), and builds
  the per-locale copies `mix mobile.strings` writes to
  `mobile/shared/strings/<locale>.json`.

  `Kanban.Mobile.Strings.Msgids` lists every app string through
  `dpgettext_noop/3`, and `msgids/0` hands them on, so
  `MIX_ENV=test mix gettext.extract --merge` keeps `priv/gettext/mobile.pot`
  and each locale's `mobile.po` in step with this module. Each string's
  `msgctxt` is its key: a stable snake_case id the app generators use as the
  resource name, so changing the wording never renames a resource. The status
  labels and the risk explainer sentence are copied from the web's default
  domain, and `test/kanban/mobile/strings_test.exs` fails when the two read
  differently or a committed copy is stale. Refresh the copies with
  `MIX_ENV=test mix mobile.strings`, and never edit them by hand. The same task
  writes the iOS app's string catalog, which `Kanban.Mobile.StringCatalog` builds
  from the same strings.

  ## What each locale's file holds

    * `strings`: `key => text` for each singular message.
    * `plurals`: `key => %{category => text}`, keyed by the CLDR plural
      category (`one`, `other`) the apps' plural resources use, derived from
      the locale's `Plural-Forms` header.
    * `generator`, `locale` and `source`, the `.po` file it came from.

  gettext's `%{name}` placeholders become `{name}`, a neutral form each app's
  generator maps to its own format. Keys are sorted at every level so the
  files diff cleanly.

  ## What fails

  `parse!/2` raises `ArgumentError`, naming the locale and the key, when a
  file is missing, a key is missing, unknown, duplicated or malformed, a
  message is fuzzy or obsolete, a translation is empty, a plural has the wrong
  number of forms, the `Plural-Forms` rule is not one of the three these
  locales use, a translation loses or invents a placeholder, or a translation
  holds a brace that is not part of a `%{name}` placeholder.
  """
  alias Expo.Message
  alias Expo.Message.Plural
  alias Expo.Message.Singular
  alias Expo.Messages
  alias Expo.PluralForms
  alias Expo.PO

  @locales ~w(de en es fr ja pt zh)
  @source_path "priv/gettext"
  @output_dir "mobile/shared/strings"

  @key_re ~r/^[a-z][a-z0-9_]*$/
  @placeholder_re ~r/%\{([a-z_][a-z0-9_]*)\}/

  # The plural index each Plural-Forms rule gives n = 0, 1 and 2, and the CLDR
  # categories those indexes stand for.
  @categories %{
    [0, 0, 0] => ~w(other),
    [1, 0, 1] => ~w(one other),
    [0, 0, 1] => ~w(one other)
  }

  @type locale_strings :: %{String.t() => term()}

  @doc "The seven locales the apps ship, in the order of their file names."
  @spec locales() :: [String.t()]
  def locales, do: @locales

  @doc """
  The English text of every app string, from `Kanban.Mobile.Strings.Msgids`.
  """
  @spec msgids() :: [String.t() | {String.t(), String.t()}]
  defdelegate msgids, to: Kanban.Mobile.Strings.Msgids

  @doc "The gettext directory the strings come from, relative to the project root."
  @spec source_path() :: String.t()
  def source_path, do: @source_path

  @doc "The folder the copies are written to, relative to the project root."
  @spec output_dir() :: String.t()
  def output_dir, do: @output_dir

  @doc "The copy for one locale, relative to the project root."
  @spec output_path(String.t()) :: String.t()
  def output_path(locale), do: Path.join(@output_dir, locale <> ".json")

  @doc """
  Reads `mobile.pot` and one locale's `mobile.po` under `gettext_dir` and
  returns that locale's strings. Raises `ArgumentError` naming the locale and
  the key that is wrong.
  """
  @spec parse!(Path.t(), String.t()) :: locale_strings()
  def parse!(gettext_dir, locale) do
    known_locale!(locale)
    pot = gettext_dir |> Path.join("mobile.pot") |> read_po!(locale)
    po = [gettext_dir, locale, "LC_MESSAGES", "mobile.po"] |> Path.join() |> read_po!(locale)

    reject_obsolete!(po, locale)
    compare_keys!(keys!(pot, locale), keys!(po, locale), locale)
    categories = plural_categories!(po, locale)

    po.messages
    |> Enum.map(&entry!(&1, locale, categories))
    |> to_locale_strings(locale)
  end

  @doc "Builds every locale's strings, keyed by locale."
  @spec build!(Path.t()) :: %{String.t() => locale_strings()}
  def build!(gettext_dir), do: Map.new(@locales, &{&1, parse!(gettext_dir, &1)})

  @doc "Renders every locale's file: pretty JSON, keys sorted, ending in a newline."
  @spec render!(Path.t()) :: %{String.t() => String.t()}
  def render!(gettext_dir) do
    gettext_dir
    |> build!()
    |> Map.new(fn {locale, strings} -> {locale, encode(strings)} end)
  end

  defp known_locale!(locale) when locale in @locales, do: :ok

  defp known_locale!(locale) do
    raise ArgumentError,
          "mobile.strings: #{inspect(locale)} is not one of #{Enum.join(@locales, ", ")}"
  end

  defp read_po!(path, locale) do
    if File.regular?(path),
      do: PO.parse_file!(path),
      else: invalid!(locale, Path.basename(path), "is missing at #{path}")
  end

  defp reject_obsolete!(%Messages{messages: messages}, locale) do
    case Enum.find(messages, & &1.obsolete) do
      nil -> :ok
      message -> invalid!(locale, key_or_msgid(message), "is obsolete; remove it")
    end
  end

  defp keys!(%Messages{messages: messages}, locale) do
    keys = Enum.map(messages, &key!(&1, locale))

    case keys -- Enum.uniq(keys) do
      [] -> keys
      [duplicate | _] -> invalid!(locale, duplicate, "is used by more than one message")
    end
  end

  defp key!(message, locale) do
    key = key_or_msgid(message)

    cond do
      message.msgctxt == nil -> invalid!(locale, key, "has no msgctxt key")
      Regex.match?(@key_re, key) -> key
      true -> invalid!(locale, key, "is not a snake_case key")
    end
  end

  defp key_or_msgid(%{msgctxt: nil} = message), do: message |> Message.key() |> elem(1)
  defp key_or_msgid(%{msgctxt: msgctxt}), do: IO.iodata_to_binary(msgctxt)

  defp compare_keys!(pot_keys, po_keys, locale) do
    case {pot_keys -- po_keys, po_keys -- pot_keys} do
      {[], []} -> :ok
      {[missing | _], _} -> invalid!(locale, missing, "is in mobile.pot but not in mobile.po")
      {[], [extra | _]} -> invalid!(locale, extra, "is in mobile.po but not in mobile.pot")
    end
  end

  defp plural_categories!(po, locale) do
    case Messages.get_header(po, "Plural-Forms") do
      [] -> invalid!(locale, "Plural-Forms", "header is missing")
      header -> header |> IO.iodata_to_binary() |> categories!(locale)
    end
  end

  defp categories!(header, locale) do
    plural_forms = PluralForms.parse!(header)
    signature = Enum.map(0..2, &PluralForms.index(plural_forms, &1))

    case Map.fetch(@categories, signature) do
      {:ok, categories} -> categories
      :error -> invalid!(locale, "Plural-Forms", "#{inspect(header)} is not supported")
    end
  end

  defp entry!(%Singular{} = message, locale, _categories) do
    key = key_or_msgid(message)
    reject_fuzzy!(message, locale, key)
    expected = message.msgid |> IO.iodata_to_binary() |> placeholders()
    text = IO.iodata_to_binary(message.msgstr)

    check_text!(text, locale, key)
    check_placeholders!(text, expected, [], locale, key)
    {:string, key, neutral(text)}
  end

  defp entry!(%Plural{} = message, locale, categories) do
    key = key_or_msgid(message)
    reject_fuzzy!(message, locale, key)
    forms = plural_forms(message)

    if length(forms) != length(categories),
      do: invalid!(locale, key, "has #{length(forms)} plural forms, not #{length(categories)}")

    expected = message.msgid_plural |> IO.iodata_to_binary() |> placeholders()

    texts =
      categories
      |> Enum.zip(forms)
      |> Map.new(&plural_form!(&1, expected, locale, key))

    {:plural, key, texts}
  end

  defp plural_forms(%Plural{msgstr: msgstr}) do
    msgstr
    |> Enum.sort()
    |> Enum.map(fn {_index, text} -> IO.iodata_to_binary(text) end)
  end

  # A `one` form may leave out the count ("One task" rather than "1 task").
  defp plural_form!({category, text}, expected, locale, key) do
    droppable = if category == "one", do: ["count"], else: []
    check_text!(text, locale, key)
    check_placeholders!(text, expected, droppable, locale, key)
    {category, neutral(text)}
  end

  defp reject_fuzzy!(message, locale, key) do
    if Message.has_flag?(message, "fuzzy"),
      do: invalid!(locale, key, "is fuzzy; check the translation and remove the flag")
  end

  defp check_text!(text, locale, key) do
    cond do
      String.trim(text) == "" ->
        invalid!(locale, key, "has an empty translation")

      @placeholder_re |> Regex.replace(text, "") |> String.contains?(["{", "}"]) ->
        invalid!(locale, key, "has a brace outside a %{name} placeholder: #{inspect(text)}")

      true ->
        :ok
    end
  end

  defp check_placeholders!(text, expected, droppable, locale, key) do
    found = placeholders(text)
    missing = expected -- found

    cond do
      found -- expected != [] ->
        invalid!(
          locale,
          key,
          "has placeholders the msgid lacks: #{Enum.join(found -- expected, ", ")}"
        )

      missing -- droppable != [] ->
        invalid!(locale, key, "drops placeholders: #{Enum.join(missing, ", ")}")

      true ->
        :ok
    end
  end

  defp placeholders(text) do
    @placeholder_re
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp neutral(text), do: Regex.replace(@placeholder_re, text, "{\\1}")

  defp to_locale_strings(entries, locale) do
    %{
      "generator" => "mix mobile.strings",
      "locale" => locale,
      "source" => Path.join([@source_path, locale, "LC_MESSAGES", "mobile.po"]),
      "strings" => for({:string, key, text} <- entries, into: %{}, do: {key, text}),
      "plurals" => for({:plural, key, texts} <- entries, into: %{}, do: {key, texts})
    }
  end

  defp encode(strings) do
    strings
    |> ordered()
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp ordered(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, ordered(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp ordered(value), do: value

  @spec invalid!(String.t(), String.t(), String.t()) :: no_return()
  defp invalid!(locale, key, reason) do
    raise ArgumentError, "mobile.strings: #{locale} #{key} #{reason}"
  end
end
