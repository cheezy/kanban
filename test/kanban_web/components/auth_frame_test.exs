defmodule KanbanWeb.AuthFrameTest do
  @moduledoc """
  Unit tests for the editorial auth shell built per
  `design_handoff_stride/design_source/screens/auth.jsx`.

  These tests assert that:
    * the canonical Stride design tokens are used (--ink, --surface, --line,
      --stride-orange, --stride-violet, --st-done);
    * the rotating editorial quote is selected by `quote_key`;
    * the left brand panel renders the logo gradient and decorative blobs;
    * the right form column renders the inner_block + footer_switch slot;
    * primary_full_button uses background var(--ink) (NOT a blue gradient);
    * sso_row renders the three known providers with the right glyphs;
    * no blue Tailwind classes leak into any rendered output.
  """

  use KanbanWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias KanbanWeb.AuthFrame

  describe "auth_frame/1 — left brand panel" do
    test "renders the Stride brand mark with the orange→violet logo gradient" do
      html = render_default()

      assert html =~ "linear-gradient(135deg, var(--stride-orange) 0%, var(--stride-violet) 100%)"
      # The letter glyph + Stride wordmark
      assert html =~ "Stride"
    end

    test "renders the decorative orange blob top-right and violet blob bottom-left" do
      html = render_default()

      assert html =~
               "background: radial-gradient(circle, var(--stride-orange) 0%, transparent 70%)"

      assert html =~
               "background: radial-gradient(circle, var(--stride-violet) 0%, transparent 70%)"

      assert html =~ "filter: blur(80px)"
      assert html =~ "filter: blur(90px)"
    end

    test "renders the warm-gradient brand panel background verbatim from the design" do
      html = render_default()

      assert html =~
               "linear-gradient(155deg, oklch(96% 0.025 60) 0%, oklch(94% 0.035 280) 100%)"
    end

    test "renders the green 'All systems normal' indicator using --st-done" do
      html = render_default()

      assert html =~ "All systems normal"
      assert html =~ "color: var(--st-done)"
    end

    test "renders the footer links: Privacy, Terms, Security" do
      html = render_default()

      assert html =~ "Privacy"
      assert html =~ "Terms"
      assert html =~ "Security"
    end
  end

  describe "auth_frame/1 — rotating quote" do
    test "renders the signin quote when quote_key=:signin" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AuthFrame.auth_frame quote_key={:signin}>
          <span>body</span>
        </AuthFrame.auth_frame>
        """)

      assert html =~ "Agents finally have somewhere good to work."
      assert html =~ "Jamie K"
    end

    test "renders the signup quote when quote_key=:signup" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AuthFrame.auth_frame quote_key={:signup}>
          <span>body</span>
        </AuthFrame.auth_frame>
        """)

      assert html =~ "shipped 38%"
      assert html =~ "Mei L"
    end

    test "renders the forgot quote when quote_key=:forgot" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AuthFrame.auth_frame quote_key={:forgot}>
          <span>body</span>
        </AuthFrame.auth_frame>
        """)

      assert html =~ "A task structure that AI agents can actually pull from."
      assert html =~ "Rohan S"
    end

    test "renders the magic-link quote when quote_key=:magic" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AuthFrame.auth_frame quote_key={:magic}>
          <span>body</span>
        </AuthFrame.auth_frame>
        """)

      assert html =~ "Tokens rotate, claims survive"
      assert html =~ "Dani O"
    end

    test "renders the twofa quote when quote_key=:twofa" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AuthFrame.auth_frame quote_key={:twofa}>
          <span>body</span>
        </AuthFrame.auth_frame>
        """)

      assert html =~ "Security model is built for agents"
    end

    test "falls back to the signin quote when quote_key is unknown" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AuthFrame.auth_frame quote_key={:nonexistent}>
          <span>body</span>
        </AuthFrame.auth_frame>
        """)

      assert html =~ "Agents finally have somewhere good to work."
    end
  end

  describe "auth_frame/1 — right form column" do
    test "renders the inner_block content in the right column" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AuthFrame.auth_frame quote_key={:signin}>
          <form id="form-under-test"><input name="email" /></form>
        </AuthFrame.auth_frame>
        """)

      assert html =~ ~s(id="form-under-test")
      assert html =~ ~s(name="email")
    end

    test "renders the footer_switch slot in the top-right" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AuthFrame.auth_frame quote_key={:signin}>
          <:footer_switch>
            <span data-cross-state>New here? Sign up</span>
          </:footer_switch>
          <span>body</span>
        </AuthFrame.auth_frame>
        """)

      assert html =~ "data-cross-state"
      assert html =~ "New here? Sign up"
    end

    test "constrains the form column to max-width 440 per the design" do
      html = render_default()

      assert html =~ "max-width: 440px"
    end
  end

  describe "auth_frame/1 — design-token compliance" do
    test "outer wrapper has the stride-screen class so Geist typography applies" do
      html = render_default()

      assert html =~ ~s(class="stride-screen")
    end

    test "uses the design's ink color tokens, not daisyUI base-* classes" do
      html = render_default()

      assert html =~ "var(--ink)"
      assert html =~ "var(--ink-3)"
      assert html =~ "var(--line)"
      assert html =~ "var(--bg)"
    end

    test "renders no blue Tailwind classes anywhere" do
      html = render_default()

      refute html =~ ~r/(text|bg|from|to|border)-blue-\d+/
    end

    test "renders no forbidden gray/white Tailwind classes" do
      html = render_default()

      refute html =~ ~r/(text|bg|border)-gray-\d+/
      refute html =~ "bg-white"
    end
  end

  describe "primary_full_button/1" do
    test "uses background var(--ink) and white text — NOT blue" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AuthFrame.primary_full_button>Sign in</AuthFrame.primary_full_button>
        """)

      assert html =~ "background: var(--ink)"
      assert html =~ "color: white"
      assert html =~ "Sign in"
      refute html =~ ~r/(text|bg|from|to|border)-blue-\d+/
    end

    test "renders at height 40 with 6px border-radius per the design" do
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

  describe "sso_row/1" do
    test "renders the Google provider with the multicolor glyph and Google label" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AuthFrame.sso_row provider={:google} />
        """)

      assert html =~ "Continue with"
      assert html =~ "Google"
      assert html =~ ~s(fill="#4285F4")
      assert html =~ ~s(fill="#34A853")
      assert html =~ ~s(fill="#FBBC05")
      assert html =~ ~s(fill="#EA4335")
    end

    test "renders the GitHub provider with the silhouette glyph and label" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AuthFrame.sso_row provider={:github} />
        """)

      assert html =~ "GitHub"
      assert html =~ ~s(fill="currentColor")
    end

    test "renders the SAML provider with the lock glyph and SSO label" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AuthFrame.sso_row provider={:saml} />
        """)

      assert html =~ "SSO (SAML)"
      assert html =~ ~s(<rect x="2" y="6")
    end

    test "uses surface bg + line-strong border, not blue" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AuthFrame.sso_row provider={:google} />
        """)

      assert html =~ "background: var(--surface)"
      assert html =~ "border: 1px solid var(--line-strong)"
      refute html =~ ~r/(text|bg|from|to|border)-blue-\d+/
    end
  end

  defp render_default do
    assigns = %{}

    rendered_to_string(~H"""
    <AuthFrame.auth_frame quote_key={:signin}>
      <span>body</span>
    </AuthFrame.auth_frame>
    """)
  end
end
