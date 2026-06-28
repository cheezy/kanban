defmodule KanbanWeb.NavComponentsTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.NavComponents

  describe "mobile_menu/1" do
    test "renders an md:hidden hamburger disclosure with accessibility attributes" do
      assigns = %{current_scope: nil}

      html =
        rendered_to_string(~H"""
        <NavComponents.mobile_menu current_scope={@current_scope} />
        """)

      # Native <details> disclosure, collapsed at desktop width.
      assert html =~ "<details"
      assert html =~ "md:hidden"
      assert html =~ "<summary"

      # Accessible toggle: label, controls target, and expanded state.
      assert html =~ ~s|aria-label="Toggle menu"|
      assert html =~ ~s|aria-controls="root-mobile-menu"|
      assert html =~ ~s|aria-expanded="false"|

      # The dropdown panel the summary controls.
      assert html =~ ~s|id="root-mobile-menu"|

      # Hamburger/close glyphs use the shared <.icon> hero component (rendered
      # as hero-* span classes), not hand-rolled inline SVG.
      assert html =~ "hero-bars-3"
      assert html =~ "hero-x-mark"
    end

    test "summary is a 44px touch target" do
      assigns = %{current_scope: nil}

      html =
        rendered_to_string(~H"""
        <NavComponents.mobile_menu current_scope={@current_scope} />
        """)

      # w-11 h-11 = 44x44px, the minimum comfortable tap target.
      assert html =~ "w-11"
      assert html =~ "h-11"
    end

    test "renders the unauthenticated link set when current_scope is nil" do
      assigns = %{current_scope: nil}

      html =
        rendered_to_string(~H"""
        <NavComponents.mobile_menu current_scope={@current_scope} />
        """)

      assert html =~ ~s|href="/resources"|
      assert html =~ ~s|href="/about"|
      assert html =~ ~s|href="/users/log-in"|
      assert html =~ ~s|href="/users/register"|

      # Authenticated-only destinations must not leak to signed-out visitors.
      refute html =~ ~s|href="/boards"|
      refute html =~ ~s|href="/users/settings"|
      refute html =~ ~s|href="/admin/dashboard"|
    end

    test "renders the authenticated member link set" do
      assigns = %{
        current_scope: %{user: %{email: "member@example.com", type: :member}}
      }

      html =
        rendered_to_string(~H"""
        <NavComponents.mobile_menu current_scope={@current_scope} />
        """)

      assert html =~ "member@example.com"
      assert html =~ ~s|href="/boards"|
      assert html =~ ~s|href="/users/settings"|
      assert html =~ ~s|href="/resources"|
      assert html =~ ~s|href="/about"|
      assert html =~ ~s|href="/users/log-out"|

      # Members never see the admin-only links.
      refute html =~ ~s|href="/admin/dashboard"|
      refute html =~ ~s|href="/admin/errors"|
    end

    test "renders admin-only links for admin users" do
      assigns = %{
        current_scope: %{user: %{email: "admin@example.com", type: :admin}}
      }

      html =
        rendered_to_string(~H"""
        <NavComponents.mobile_menu current_scope={@current_scope} />
        """)

      assert html =~ ~s|href="/admin/dashboard"|
      assert html =~ ~s|href="/admin/errors"|
      assert html =~ ~s|href="/boards"|
    end

    test "menu links use theme-aware tokens, not hardcoded colors" do
      assigns = %{current_scope: nil}

      html =
        rendered_to_string(~H"""
        <NavComponents.mobile_menu current_scope={@current_scope} />
        """)

      # daisyUI/Stride tokens keep the menu correct in dark mode.
      assert html =~ "text-base-content"
      assert html =~ "bg-base-100"

      # No theme-blind grey/white classes.
      refute html =~ "text-gray-"
      refute html =~ "bg-white"
      refute html =~ "bg-gray-"
    end
  end
end
