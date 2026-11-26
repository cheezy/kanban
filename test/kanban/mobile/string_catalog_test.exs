defmodule Kanban.Mobile.StringCatalogTest do
  @moduledoc """
  The iOS app's string catalog, generated from the `mobile` gettext domain
  (W2785, W2788).
  """
  use ExUnit.Case, async: true

  alias Kanban.Mobile.StringCatalog
  alias Kanban.Mobile.Strings

  doctest StringCatalog

  @root Path.expand("../../..", __DIR__)
  @gettext Path.join(@root, "priv/gettext")
  @ios_locales ~w(de en es fr ja pt zh-Hans)

  defp committed, do: @root |> Path.join(StringCatalog.output_path()) |> File.read!()

  # The catalog as the generator renders it now, so a test of its shape fails on
  # the generator itself and not only through the staleness test.
  defp rendered, do: @gettext |> Strings.build!() |> StringCatalog.render() |> JSON.decode!()

  defp strings(overrides), do: Map.new(Strings.locales(), &{&1, %{"strings" => overrides}})

  defp keys_sorted?(%Jason.OrderedObject{values: values}) do
    keys = Enum.map(values, &elem(&1, 0))
    keys == Enum.sort(keys) and Enum.all?(values, fn {_key, value} -> keys_sorted?(value) end)
  end

  defp keys_sorted?(_value), do: true

  test "the committed catalog matches the mobile domain" do
    assert committed() == @gettext |> Strings.build!() |> StringCatalog.render(),
           "#{StringCatalog.output_path()} is stale. " <>
             "Refresh it with: MIX_ENV=test mix mobile.strings"
  end

  test "the catalog holds every locale's text under the name iOS uses" do
    catalog = rendered()

    assert catalog["sourceLanguage"] == "en"
    assert catalog["version"] == "1.0"

    for {_key, entry} <- catalog["strings"] do
      assert entry["extractionState"] == "manual"
      assert entry["localizations"] |> Map.keys() |> Enum.sort() == @ios_locales
    end

    for {locale, %{"strings" => strings}} <- Strings.build!(@gettext),
        {key, text} <- strings,
        !String.contains?(text, "{") do
      name = if locale == "zh", do: "zh-Hans", else: locale

      assert catalog["strings"][key]["localizations"][name]["stringUnit"] ==
               %{"state" => "translated", "value" => text}
    end
  end

  test "the catalog holds every string and every plural" do
    %{"strings" => strings, "plurals" => plurals} = Strings.build!(@gettext)["en"]
    catalog = rendered()["strings"]

    expected = (Map.keys(strings) ++ Map.keys(plurals)) |> Enum.sort()

    assert catalog |> Map.keys() |> Enum.sort() == expected
  end

  test "render/1 turns placeholders into positional specifiers in each locale's order" do
    catalog =
      %{
        "en" => %{"strings" => %{"a" => "{estimate} after {target_date}, 100%"}},
        "de" => %{"strings" => %{"a" => "Nach {target_date}: {estimate}"}}
      }
      |> StringCatalog.render()
      |> JSON.decode!()

    localizations = catalog["strings"]["a"]["localizations"]

    assert localizations["en"]["stringUnit"]["value"] == "%1$@ after %2$@, 100%%"
    assert localizations["de"]["stringUnit"]["value"] == "Nach %2$@: %1$@"
  end

  test "render/1 leaves a string without a placeholder as it is" do
    catalog = %{"a" => "100% plain"} |> strings() |> StringCatalog.render() |> JSON.decode!()

    assert catalog["strings"]["a"]["localizations"]["en"]["stringUnit"]["value"] == "100% plain"
  end

  test "a plural of count alone varies by the locale's categories" do
    catalog = rendered()["strings"]["target_goal_count"]["localizations"]

    assert catalog["de"]["variations"]["plural"] == %{
             "one" => %{"stringUnit" => %{"state" => "translated", "value" => "%1$lld Ziel"}},
             "other" => %{"stringUnit" => %{"state" => "translated", "value" => "%1$lld Ziele"}}
           }

    for locale <- ~w(ja zh-Hans) do
      assert catalog[locale]["variations"]["plural"] |> Map.keys() == ["other"]
    end
  end

  test "a plural with more arguments varies through a count substitution" do
    localization =
      rendered()["strings"]["target_task_progress"]["localizations"]["ja"]

    assert localization["stringUnit"]["value"] == "%#@count@"

    assert localization["substitutions"]["count"] == %{
             "argNum" => 2,
             "formatSpecifier" => "lld",
             "variations" => %{
               "plural" => %{
                 "other" => %{
                   "stringUnit" => %{"state" => "translated", "value" => "タスク %2$lld 件中 %1$lld 件"}
                 }
               }
             }
           }
  end

  test "render/1 sorts the keys at every level and ends in a newline" do
    catalog = %{"b" => "B", "c" => "C", "a" => "A"} |> strings() |> StringCatalog.render()

    assert catalog |> Jason.decode!(objects: :ordered_objects) |> keys_sorted?()
    assert String.ends_with?(catalog, "}\n")
  end

  test "output_path/0 is in the app's resources" do
    assert StringCatalog.output_path() == "mobile/ios/Stride/Resources/Localizable.xcstrings"
  end
end
