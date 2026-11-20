defmodule KanbanWeb.Components.DeviceListTest do
  @moduledoc """
  The markup of `KanbanWeb.Components.DeviceList.device_list/1`, shared by the
  Devices section of `/users/settings` and a member's devices in the org
  console: theme tokens only, long names that wrap, and translated labels.
  The pages that host it are covered in
  `KanbanWeb.UserLive.SettingsDevicesTest` and
  `KanbanWeb.OrgLive.ConsoleDevicesTest`.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Kanban.Devices.Device
  alias KanbanWeb.Components.DeviceList

  # One unbroken 120-character name: it can only fit a 320px phone if it
  # breaks inside the word.
  @long_name String.duplicate("Ada", 40)

  defp device(attrs) do
    struct!(
      %Device{
        id: 1,
        name: "Ada's iPhone",
        platform: :ios,
        device_class: :phone,
        app_version: "1.0.0 (42)",
        last_seen_at: nil
      },
      attrs
    )
  end

  defp list(devices, locale \\ "en") do
    Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
      render_component(&DeviceList.device_list/1,
        id: "device-list",
        id_prefix: "device",
        devices: devices,
        revoke_event: "revoke_device",
        revoke_confirm: "Revoke?",
        empty_text: "Nothing here."
      )
    end)
  end

  defp styles(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[style]")
    |> LazyHTML.attribute("style")
  end

  test "colours come only from theme tokens" do
    html = list([device(%{}), device(%{id: 2, platform: :android, device_class: :tablet})])
    empty = list([])

    for style <- styles(html) ++ styles(empty), style =~ ~r/color|background|border/ do
      refute style =~ ~r/#[0-9a-fA-F]{3,8}\b|rgba?\(|hsla?\(|oklch\(|\b(white|black)\b/,
             "a hardcoded colour in #{inspect(style)}"
    end

    assert html =~ "color: var(--ink);"
    assert html =~ "color: var(--ink-2);"
    assert html =~ "border-bottom: 1px solid var(--line);"
    assert empty =~ "color: var(--ink-2);"
    refute html =~ ~r/\b(text|bg|border)-(gray|slate|zinc|neutral|white|black)\b/
  end

  test "a long device name wraps inside the word instead of overflowing" do
    doc = [device(%{name: @long_name})] |> list() |> LazyHTML.from_fragment()

    [name_style] = doc |> LazyHTML.query("#device-name-1") |> LazyHTML.attribute("style")
    assert name_style =~ "overflow-wrap: anywhere;"
    assert doc |> LazyHTML.query("#device-name-1") |> LazyHTML.text() =~ @long_name

    # its column may shrink below the name's width, or the wrap never happens
    assert doc |> LazyHTML.query(~s([class*="min-w-0"] > #device-name-1)) |> Enum.count() == 1

    [version_style] = doc |> LazyHTML.query("#device-version-1") |> LazyHTML.attribute("style")
    assert version_style =~ "overflow-wrap: anywhere;"
  end

  test "renders its labels in German" do
    seen = device(%{id: 2, last_seen_at: ~U[2026-11-18 13:30:00Z]})
    doc = [device(%{}), seen] |> list("de") |> LazyHTML.from_fragment()
    text = &(doc |> LazyHTML.query(&1) |> LazyHTML.text())

    assert text.("#device-kind-1") =~ "iOS · Telefon"
    assert text.("#device-version-1") =~ "App 1.0.0 (42)"
    assert text.("#device-last-seen-1") =~ "Zuletzt gesehen"
    assert text.("#device-last-seen-1") =~ "Nie"
    assert text.("#device-revoke-1") =~ "Widerrufen"
    assert doc |> LazyHTML.query("#device-last-seen-2 time[datetime]") |> Enum.count() == 1

    for english <- ["Last seen", "Never", "Revoke", "Phone"] do
      # word boundaries, so the name "Ada's iPhone" does not count as "Phone"
      refute LazyHTML.text(doc) =~ ~r/\b#{english}\b/
    end
  end

  test "a device with no app version or a platform it does not know still renders" do
    doc =
      [device(%{app_version: nil, platform: nil, device_class: nil})]
      |> list()
      |> LazyHTML.from_fragment()

    assert doc |> LazyHTML.query("#device-version-1") |> LazyHTML.text() =~ "—"
    assert doc |> LazyHTML.query("#device-kind-1") |> LazyHTML.text() |> String.trim() == ""
  end
end
