defmodule KanbanWeb.UserLive.SettingsComponentsTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KanbanWeb.UserLive.SettingsComponents

  defp shell(assigns) do
    render_component(
      &SettingsComponents.settings_shell/1,
      Map.merge(%{inner_block: [%{inner_block: fn _, _ -> "SECTION BODY" end}]}, assigns)
    )
  end

  describe "account_section_path/1" do
    test "points Profile at the settings page and Password at its tab" do
      assert SettingsComponents.account_section_path(:profile) == "/users/settings"

      assert SettingsComponents.account_section_path(:password) ==
               "/users/settings?section=password"
    end
  end

  describe "settings_shell/1" do
    test "renders the header, the section body and the 44px-rule anchor" do
      html = shell(%{active: :profile})

      assert html =~ "data-settings-panel"
      assert html =~ "Settings"
      assert html =~ "Manage your profile, password and notifications"
      assert html =~ "SECTION BODY"
    end

    test "with tabs, Profile and Password are in-page tabs and Notifications is a link" do
      html = shell(%{active: :password, tabs: true})
      doc = LazyHTML.from_fragment(html)

      assert doc |> LazyHTML.query(~s([role="tablist"] button[role="tab"])) |> Enum.count() == 2

      assert doc
             |> LazyHTML.query(~s(button[aria-selected="true"][phx-value-section="password"]))
             |> Enum.count() == 1

      assert doc
             |> LazyHTML.query(~s(a#settings-notifications-link[href="/users/notifications"]))
             |> Enum.count() == 1

      refute html =~ "settings-profile-link"
      refute html =~ ~s(aria-current="page")
    end

    test "without tabs, every section is a link and the active one is the current page" do
      html = shell(%{active: :notifications})
      doc = LazyHTML.from_fragment(html)

      refute html =~ ~s(role="tablist")
      refute html =~ ~s(role="tab")

      assert doc
             |> LazyHTML.query(~s(a#settings-profile-link[href="/users/settings"]))
             |> Enum.count() == 1

      assert doc
             |> LazyHTML.query(
               ~s(a#settings-password-link[href="/users/settings?section=password"])
             )
             |> Enum.count() == 1

      assert doc
             |> LazyHTML.query(~s(a#settings-notifications-link[aria-current="page"]))
             |> Enum.count() == 1

      # menu links carry the phone tap height the panel CSS gives buttons
      assert doc |> LazyHTML.query(~s(a#settings-profile-link[class*="min-h-11"])) |> Enum.count() ==
               1
    end
  end

  describe "settings_card/1" do
    test "renders the title at the requested heading level with an optional hint" do
      html =
        render_component(&SettingsComponents.settings_card/1,
          id: "card",
          title: "Group title",
          hint: "A hint",
          level: 3,
          compact: true,
          inner_block: [%{inner_block: fn _, _ -> "CARD BODY" end}]
        )

      assert html =~ ~s(id="card")
      assert html =~ ~r{<h3[^>]*>\s*Group title\s*</h3>}
      assert html =~ "A hint"
      assert html =~ "padding: 4px 18px 8px;"
      assert html =~ "CARD BODY"
    end

    test "defaults to an h2 title, no hint and roomy padding" do
      html =
        render_component(&SettingsComponents.settings_card/1,
          title: "Profile",
          inner_block: [%{inner_block: fn _, _ -> "BODY" end}]
        )

      assert html =~ ~r{<h2[^>]*>\s*Profile\s*</h2>}
      refute html =~ "<p"
      assert html =~ "padding: 18px;"
    end
  end
end
