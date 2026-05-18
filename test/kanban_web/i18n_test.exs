defmodule KanbanWeb.I18nTest do
  @moduledoc """
  Locale-completeness regression test.

  Iterates the .po files for every non-English locale and asserts none of
  them contain an empty `msgstr` (singular) or empty `msgstr[0]`/`msgstr[1]`
  (plural). English is intentionally exempt because an empty `msgstr` in
  `priv/gettext/en/LC_MESSAGES/*.po` correctly falls back to the `msgid`.

  Without this guard, the next contributor who runs `mix gettext.extract
  --merge` and lands a new `msgid` would silently introduce gaps in every
  non-English locale.
  """
  use ExUnit.Case, async: true

  alias Expo.Message
  alias Expo.Messages
  alias Expo.PO

  @locales ~w(de es fr ja pt zh)
  @domains ~w(default errors)

  describe "priv/gettext locale completeness" do
    test "no non-English locale has an empty msgstr in default.po or errors.po" do
      gaps =
        for locale <- @locales,
            domain <- @domains,
            entry <- empty_msgstrs(locale, domain) do
          entry
        end

      assert gaps == [], """
      Found empty translations in non-English locales:

      #{format_gaps(gaps)}

      Fill the missing msgstrs in the listed .po files, or extend the
      whitelist in #{__ENV__.file} if any entry is intentionally untranslatable.
      """
    end
  end

  defp empty_msgstrs(locale, domain) do
    path = Path.join([:code.priv_dir(:kanban), "gettext", locale, "LC_MESSAGES", "#{domain}.po"])

    %Messages{messages: messages} = PO.parse_file!(path)

    messages
    |> Enum.reject(&Message.has_flag?(&1, "obsolete"))
    |> Enum.flat_map(&empty_for_message(&1, locale, domain))
  end

  # Singular: %Message.Singular{msgid: [..], msgstr: [..]}.
  # An empty msgstr is either an empty list or a list of empty strings.
  defp empty_for_message(%Message.Singular{msgid: msgid, msgstr: msgstr}, locale, domain) do
    case joined_text(msgid) do
      "" ->
        # The PO header has an empty msgid and a populated msgstr (Language:
        # …, Plural-Forms: …). Skip it.
        []

      msgid_text ->
        if blank?(msgstr) do
          [%{locale: locale, domain: domain, msgid: msgid_text, form: :singular}]
        else
          []
        end
    end
  end

  # Plural: %Message.Plural{msgid: [..], msgid_plural: [..], msgstr: %{0 => [..], 1 => [..], ...}}
  # Every form (0..n) must be populated.
  defp empty_for_message(%Message.Plural{msgid: msgid, msgstr: msgstr}, locale, domain) do
    msgid_text = joined_text(msgid)

    msgstr
    |> Enum.filter(fn {_form, value} -> blank?(value) end)
    |> Enum.map(fn {form, _value} ->
      %{locale: locale, domain: domain, msgid: msgid_text, form: {:plural, form}}
    end)
  end

  defp joined_text(parts) when is_list(parts), do: parts |> Enum.join("") |> String.trim()
  defp joined_text(_), do: ""

  # An msgstr is "blank" if every continuation segment is empty after trimming.
  defp blank?(parts) when is_list(parts), do: parts |> Enum.join("") |> String.trim() == ""
  defp blank?(_), do: true

  defp format_gaps(gaps) do
    gaps
    |> Enum.group_by(& &1.locale)
    |> Enum.sort()
    |> Enum.map_join("\n\n", fn {locale, entries} ->
      header = "  #{locale} (#{length(entries)} missing):"

      lines =
        entries
        |> Enum.map_join("\n", fn %{domain: domain, msgid: msgid, form: form} ->
          "    - #{domain}.po [#{format_form(form)}] msgid: #{inspect(msgid)}"
        end)

      "#{header}\n#{lines}"
    end)
  end

  defp format_form(:singular), do: "msgstr"
  defp format_form({:plural, idx}), do: "msgstr[#{idx}]"
end
