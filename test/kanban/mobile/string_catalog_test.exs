defmodule Kanban.Mobile.StringCatalogTest do
  @moduledoc """
  The iOS app's string catalog, generated from the `mobile` gettext domain
  (W2785).
  """
  use ExUnit.Case, async: true

  alias Kanban.Mobile.StringCatalog
  alias Kanban.Mobile.Strings

  @root Path.expand("../../..", __DIR__)
  @gettext Path.join(@root, "priv/gettext")
  @ios_locales ~w(de en es fr ja pt zh-Hans)

  defp committed, do: @root |> Path.join(StringCatalog.output_path()) |> File.read!()

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
    catalog = JSON.decode!(committed())

    assert catalog["sourceLanguage"] == "en"
    assert catalog["version"] == "1.0"

    for {locale, %{"strings" => strings}} <- Strings.build!(@gettext),
        {key, entry} <- catalog["strings"] do
      name = if locale == "zh", do: "zh-Hans", else: locale

      assert entry["extractionState"] == "manual"
      assert entry["localizations"] |> Map.keys() |> Enum.sort() == @ios_locales

      assert entry["localizations"][name]["stringUnit"] ==
               %{"state" => "translated", "value" => strings[key]}
    end
  end

  test "the catalog holds every string but the ones with a placeholder" do
    %{"strings" => strings} = Strings.build!(@gettext)["en"]
    catalog = JSON.decode!(committed())["strings"]

    assert Map.keys(strings) -- Map.keys(catalog) == ["target_risk_slip"]
    assert Map.keys(catalog) -- Map.keys(strings) == []
  end

  test "render/1 leaves out a string with a placeholder" do
    catalog = %{"a" => "Plain", "b" => "With {name}"} |> strings() |> StringCatalog.render()

    assert catalog |> JSON.decode!() |> Map.fetch!("strings") |> Map.keys() == ["a"]
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
