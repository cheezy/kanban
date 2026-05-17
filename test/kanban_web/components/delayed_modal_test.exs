defmodule KanbanWeb.DelayedModalTest do
  @moduledoc """
  Covers the public `delayed_modal/1` component, including the
  `mobile_fullscreen` branch and every `max_width` mapping that
  `md_max_width/1` knows how to translate. Tailwind v4's
  `source(none)` scanner only picks up literal class strings, so
  these tests double as a guard against accidentally trimming a
  clause from `md_max_width/1`.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias KanbanWeb.DelayedModal

  describe "delayed_modal/1 — base render" do
    test "renders with default max_width when not mobile_fullscreen" do
      html =
        render_component(&DelayedModal.delayed_modal/1,
          id: "demo-modal",
          inner_block: simple_inner("Hello")
        )

      assert html =~ ~s(id="demo-modal")
      assert html =~ ~s(id="demo-modal-bg")
      assert html =~ ~s(id="demo-modal-container")
      assert html =~ ~s(id="demo-modal-content")
      assert html =~ "max-w-3xl"
      # default branch must NOT emit any md:max-w-* variant
      refute html =~ "md:max-w-3xl"
      # default outer padding from non-mobile_fullscreen branch
      assert html =~ "p-4 sm:p-6"
      # close button + dialog wrapper
      assert html =~ ~s(role="dialog")
      assert html =~ ~s(aria-label="close")
      assert html =~ "Hello"
    end

    test "renders with show: true (phx-mounted shows the modal)" do
      html =
        render_component(&DelayedModal.delayed_modal/1,
          id: "shown-modal",
          show: true,
          inner_block: simple_inner("Body")
        )

      # phx-mounted attribute is only present when show: true
      assert html =~ "phx-mounted"
      assert html =~ "Body"
    end

    test "renders with a custom non-default max_width that md_max_width passes through" do
      html =
        render_component(&DelayedModal.delayed_modal/1,
          id: "unknown-width-modal",
          max_width: "max-w-prose",
          inner_block: simple_inner("X")
        )

      # Non-fullscreen branch uses max_width as-is
      assert html =~ "max-w-prose"
    end

    test "applies custom padding when provided" do
      html =
        render_component(&DelayedModal.delayed_modal/1,
          id: "padded-modal",
          padding: "p-2",
          inner_block: simple_inner("X")
        )

      # Custom padding appears on the inner container
      assert html =~ "p-2"
    end
  end

  describe "delayed_modal/1 — mobile_fullscreen branch" do
    test "renders mobile_fullscreen markers and switches to min-h-screen" do
      html =
        render_component(&DelayedModal.delayed_modal/1,
          id: "mf-modal",
          mobile_fullscreen: true,
          inner_block: simple_inner("Body")
        )

      # mobile_fullscreen wrapper switches outer padding and corner
      # rounding so the container fills the viewport on small screens.
      assert html =~ "rounded-none"
      assert html =~ "md:rounded-2xl"
      assert html =~ "min-h-screen"
      assert html =~ "md:min-h-0"
      assert html =~ "p-0 md:p-6"
    end

    # Every clause in `md_max_width/1` must be exercised so the literal
    # `md:max-w-*` class strings remain in source for Tailwind v4's
    # static scanner. The catch-all is covered above by `max-w-prose`.
    for size <-
          ~w(max-w-sm max-w-md max-w-lg max-w-xl max-w-2xl max-w-3xl max-w-4xl max-w-5xl max-w-6xl max-w-7xl) do
      test "mobile_fullscreen emits md:-prefixed variant for #{size}" do
        size = unquote(size)
        md_variant = "md:" <> size

        html =
          render_component(&DelayedModal.delayed_modal/1,
            id: "mf-#{size}",
            max_width: size,
            mobile_fullscreen: true,
            inner_block: simple_inner("X")
          )

        assert html =~ md_variant,
               "expected #{md_variant} in rendered output for max_width=#{size}"
      end
    end

    test "mobile_fullscreen with an unmapped max_width passes the value through unchanged" do
      html =
        render_component(&DelayedModal.delayed_modal/1,
          id: "mf-unknown",
          max_width: "max-w-prose",
          mobile_fullscreen: true,
          inner_block: simple_inner("X")
        )

      # The catch-all clause returns the raw value; no md: prefix added.
      assert html =~ "max-w-prose"
      refute html =~ "md:max-w-prose"
    end
  end

  defp simple_inner(text) do
    [
      %{
        __slot__: :inner_block,
        inner_block: fn _assigns, _ -> text end
      }
    ]
  end
end
