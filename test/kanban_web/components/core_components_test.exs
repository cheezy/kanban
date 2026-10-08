defmodule KanbanWeb.CoreComponentsTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.CoreComponents

  describe "flash/1" do
    test "info flash uses the muted Stride status tokens, not the bright daisyUI alert" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.flash kind={:info}>Saved</CoreComponents.flash>
        """)

      assert html =~ "Saved"
      # Dedicated flash surface + blue accent + ink text — flips with the theme (D104).
      assert html =~ "background: var(--flash-info-bg)"
      assert html =~ "color: var(--st-ready)"
      assert html =~ "color: var(--ink)"
      # No bright solid daisyUI alert (the thing that looked garish in dark).
      refute html =~ "alert-info"
    end

    test "error flash uses the muted red Stride status tokens, not the bright daisyUI alert" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.flash kind={:error}>Nope</CoreComponents.flash>
        """)

      assert html =~ "Nope"
      assert html =~ "background: var(--flash-error-bg)"
      assert html =~ "color: var(--st-blocked)"
      refute html =~ "alert-error"
    end

    test "renders an optional title above the message" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.flash kind={:error} title="Heads up">Something broke</CoreComponents.flash>
        """)

      assert html =~ "Heads up"
      assert html =~ "Something broke"
    end

    test "an info flash hides itself" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.flash kind={:info}>Saved</CoreComponents.flash>
        """)

      assert html =~ ~s(phx-hook="AutoDismissFlash")
    end

    test "an error flash stays until the user dismisses it" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.flash kind={:error}>Nope</CoreComponents.flash>
        """)

      refute html =~ "AutoDismissFlash"
      # Dismissing by click still works.
      assert html =~ "lv:clear-flash"
    end
  end

  describe "auto_dismiss_hook/1" do
    test "names the hook only for info" do
      assert CoreComponents.auto_dismiss_hook(:info) == "AutoDismissFlash"
      assert CoreComponents.auto_dismiss_hook(:error) == nil
      assert CoreComponents.auto_dismiss_hook(nil) == nil
    end
  end

  describe "show_modal/2 and hide_modal/2 (W1079 — promoted to public)" do
    test "show_modal builds the reveal command chain with the original timings" do
      ops = CoreComponents.show_modal("my-modal").ops
      encoded = Jason.encode!(ops)

      assert encoded =~ "#my-modal-bg"
      assert encoded =~ "#my-modal-container"
      assert encoded =~ ~s("time":300)
      assert encoded =~ "duration-300"
      assert encoded =~ "overflow-hidden"
      assert encoded =~ "focus_first"
      assert encoded =~ "#my-modal-content"
    end

    test "hide_modal builds the dismiss command chain with the original timings" do
      ops = CoreComponents.hide_modal("my-modal").ops
      encoded = Jason.encode!(ops)

      assert encoded =~ "#my-modal-bg"
      assert encoded =~ "#my-modal-container"
      assert encoded =~ ~s("time":200)
      assert encoded =~ "duration-200"
      assert encoded =~ "overflow-hidden"
      assert encoded =~ "pop_focus"
    end
  end

  describe "header/1" do
    test "lets the actions wrap below the title and colors the subtitle with a token" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.header>
          Title
          <:subtitle>Sub</:subtitle>
          <:actions><button>Go</button></:actions>
        </CoreComponents.header>
        """)

      assert html =~ "flex flex-wrap items-center justify-between"
      assert html =~ ~s(<div class="flex flex-wrap gap-2">)
      assert html =~ "color: var(--ink-2);"
      refute html =~ "opacity-70"
      refute html =~ "flex-none"
    end
  end

  describe "error/1" do
    test "uses the AA-checked error ink, not the error fill colour" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.error>can't be blank</CoreComponents.error>
        """)

      assert html =~ "can't be blank"
      assert html =~ "text-[var(--color-error-ink)]"
      refute html =~ ~r/\btext-error\b/
    end
  end
end
