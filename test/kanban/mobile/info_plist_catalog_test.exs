defmodule Kanban.Mobile.InfoPlistCatalogTest do
  @moduledoc """
  The iOS app's Info.plist string catalog, generated from the `mobile` gettext
  domain (W2798).
  """
  use ExUnit.Case, async: true

  alias Kanban.Mobile.InfoPlistCatalog
  alias Kanban.Mobile.Strings

  @root Path.expand("../../..", __DIR__)
  @gettext Path.join(@root, "priv/gettext")
  @ios_locales ~w(de en es fr ja pt zh-Hans)

  defp committed, do: @root |> Path.join(InfoPlistCatalog.output_path()) |> File.read!()

  defp rendered,
    do: @gettext |> Strings.build!() |> InfoPlistCatalog.render() |> JSON.decode!()

  defp strings(key, text), do: Map.new(Strings.locales(), &{&1, %{"strings" => %{key => text}}})

  test "the committed catalog matches the mobile domain" do
    assert committed() == @gettext |> Strings.build!() |> InfoPlistCatalog.render(),
           "#{InfoPlistCatalog.output_path()} is stale. " <>
             "Refresh it with: MIX_ENV=test mix mobile.strings"
  end

  test "the catalog holds each key's text in every locale, under the name iOS uses" do
    catalog = rendered()
    strings = Strings.build!(@gettext)

    assert catalog["sourceLanguage"] == "en"
    assert catalog["version"] == "1.0"
    assert catalog["strings"] |> Map.keys() == ["NSFaceIDUsageDescription"]

    for {plist_key, key} <- InfoPlistCatalog.keys() do
      entry = catalog["strings"][plist_key]

      assert entry["extractionState"] == "manual"
      assert entry["localizations"] |> Map.keys() |> Enum.sort() == @ios_locales

      for locale <- Strings.locales() do
        name = if locale == "zh", do: "zh-Hans", else: locale

        assert entry["localizations"][name]["stringUnit"] ==
                 %{"state" => "translated", "value" => strings[locale]["strings"][key]}
      end
    end
  end

  test "Face ID's reason is the app's own text in each locale" do
    localizations = rendered()["strings"]["NSFaceIDUsageDescription"]["localizations"]

    assert localizations["en"]["stringUnit"]["value"] ==
             "Stride uses Face ID to confirm your approvals."

    assert localizations["de"]["stringUnit"]["value"] ==
             "Stride bestätigt Ihre Genehmigungen mit Face ID."
  end

  test "project.yml gives each key its English text, so the Info.plist has the key" do
    project = @root |> Path.join("mobile/ios/project.yml") |> File.read!()
    english = Strings.build!(@gettext)["en"]["strings"]

    for {plist_key, key} <- InfoPlistCatalog.keys() do
      assert project =~ ~s(INFOPLIST_KEY_#{plist_key}: "#{english[key]}"),
             "mobile/ios/project.yml must set INFOPLIST_KEY_#{plist_key} to the en text of #{key}"
    end
  end

  test "render/1 refuses a missing string" do
    assert_raise ArgumentError, ~r/has no mobile string info_plist_face_id_usage/, fn ->
      "other" |> strings("Text") |> InfoPlistCatalog.render()
    end
  end

  test "render/1 refuses a placeholder, which the Info.plist cannot fill" do
    assert_raise ArgumentError, ~r/holds a placeholder/, fn ->
      "info_plist_face_id_usage" |> strings("Approve {identifier}") |> InfoPlistCatalog.render()
    end
  end

  test "render/1 sorts the keys and ends in a newline" do
    catalog = "info_plist_face_id_usage" |> strings("Text") |> InfoPlistCatalog.render()
    decoded = Jason.decode!(catalog, objects: :ordered_objects)

    assert Enum.map(decoded.values, &elem(&1, 0)) == ~w(sourceLanguage strings version)
    assert String.ends_with?(catalog, "}\n")
  end

  test "output_path/0 is in the app's resources" do
    assert InfoPlistCatalog.output_path() == "mobile/ios/Stride/Resources/InfoPlist.xcstrings"
  end
end
