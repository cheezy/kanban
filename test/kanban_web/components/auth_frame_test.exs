defmodule KanbanWeb.AuthFrameTest do
  @moduledoc """
  Unit tests for the centered, theme-aware auth shell.

  These tests assert that:
    * the centered frame uses canonical Stride design tokens (--bg, --ink,
      --ink-3) and is NOT light-locked — it follows the active theme;
    * the inner_block form and the footer_switch slot render (the Stride
      wordmark + logo gradient were removed);
    * primary_full_button uses background var(--ink) with a var(--surface)
      label (the inverted button — legible in both themes), not blue/bare-white;
    * no blue / gray / white Tailwind classes leak into any rendered output.
  """

  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.AuthFrame

  describe "auth_frame/1 — shell" do
    test "no longer renders the Stride wordmark or logo gradient" do
      # The S-gradient badge and "Stride" wordmark used to sit in the header
      # row of the auth frame. They were removed so the frame defers entirely
      # to the surrounding marketing nav for brand identity.
      html = render_default()

      refute html =~ "linear-gradient(135deg, var(--stride-orange) 0%, var(--stride-violet) 100%)"
      refute html =~ ~s(>Stride</span>)
    end

    test "is centered on the canvas and follows the theme (not light-locked)" do
      html = render_default()

      assert html =~ ~s(class="stride-screen")
      assert html =~ "background: var(--bg)"
      assert html =~ "align-items: center"
      assert html =~ "justify-content: center"
      # No light-lock attribute and no fixed light editorial gradient.
      refute html =~ "data-stride-auth-frame"
      refute html =~ "linear-gradient(155deg, oklch(96% 0.025 60)"
    end

    test "constrains the content column to max-width 440" do
      html = render_default()

      assert html =~ "max-width: 440px"
    end
  end

  describe "auth_frame/1 — slots" do
    test "renders the inner_block (form) content" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AuthFrame.auth_frame>
          <form id="form-under-test"><input name="email" /></form>
        </AuthFrame.auth_frame>
        """)

      assert html =~ ~s(id="form-under-test")
      assert html =~ ~s(name="email")
    end

    test "renders the footer_switch (cross-state) slot" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AuthFrame.auth_frame>
          <:footer_switch>
            <span data-cross-state>New here? Sign up</span>
          </:footer_switch>
          <span>body</span>
        </AuthFrame.auth_frame>
        """)

      assert html =~ "data-cross-state"
      assert html =~ "New here? Sign up"
    end
  end

  describe "auth_frame/1 — design-token compliance" do
    test "uses the design's color tokens, not daisyUI base-* classes" do
      html = render_default()

      # The default render only emits the outer canvas + the footer_switch
      # slot wrapper. var(--ink) used to appear on the (now-removed) Stride
      # wordmark — it survives via primary_full_button which is verified
      # in its own describe block below.
      assert html =~ "var(--bg)"
      assert html =~ "var(--ink-3)"
    end

    test "renders no blue Tailwind classes anywhere" do
      html = render_default()

      refute html =~ ~r/(text|bg|from|to|border)-blue-\d+/
    end

    test "renders no forbidden gray / white Tailwind classes" do
      html = render_default()

      refute html =~ ~r/(text|bg|border)-gray-\d+/
      refute html =~ "bg-white"
    end
  end

  describe "primary_full_button/1" do
    test "uses background var(--ink) with a var(--surface) label — NOT blue, NOT bare white" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AuthFrame.primary_full_button>Sign in</AuthFrame.primary_full_button>
        """)

      assert html =~ "background: var(--ink)"
      assert html =~ "color: var(--surface)"
      assert html =~ "Sign in"
      # The inverted button must NOT pin a bare white label (invisible in dark).
      refute html =~ "color: white"
      refute html =~ ~r/(text|bg|from|to|border)-blue-\d+/
    end

    test "renders at height 40 with 6px border-radius" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AuthFrame.primary_full_button>Sign in</AuthFrame.primary_full_button>
        """)

      assert html =~ "height: 40px"
      assert html =~ "border-radius: 6px"
    end

    test "renders the optional kbd chip after the label" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AuthFrame.primary_full_button kbd="↵">Sign in</AuthFrame.primary_full_button>
        """)

      assert html =~ "↵"
      assert html =~ "font-family: var(--font-mono)"
    end

    test "omits the kbd chip when not supplied" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AuthFrame.primary_full_button>Sign in</AuthFrame.primary_full_button>
        """)

      refute html =~ "font-family: var(--font-mono)"
    end

    test "renders a leading spinner when loading=true" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AuthFrame.primary_full_button loading>Verifying</AuthFrame.primary_full_button>
        """)

      assert html =~ "animation: authspin"
    end

    test "passes through type attribute via :rest" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AuthFrame.primary_full_button type="submit">Sign in</AuthFrame.primary_full_button>
        """)

      assert html =~ ~s(type="submit")
    end
  end

  defp render_default do
    assigns = %{}

    rendered_to_string(~H"""
    <AuthFrame.auth_frame>
      <span>body</span>
    </AuthFrame.auth_frame>
    """)
  end
end
