defmodule KanbanWeb.AuthFrame do
  @moduledoc """
  Editorial 2-column auth shell mirroring
  `design_handoff_stride/design_source/screens/auth.jsx` lines 34-209.

  Every auth surface (sign in, sign up, forgot password, magic-link sent,
  two-factor) renders inside `auth_frame/1`. The left column is a
  warm-gradient brand panel with decorative orange/violet blurred blobs,
  the Stride wordmark, a rotating editorial quote (selected via
  `quote_key`), and a footer with copyright + Privacy/Terms/Security
  links + an "All systems normal" status indicator. The right column is
  the form column — a max-width 440 content region centered vertically,
  with a top-right cross-state link slot and a small Contact sales · Docs
  · Status link row at the bottom.

  This component uses the Stride design tokens (`--ink`, `--surface`,
  `--line`, `--stride-orange`, `--stride-violet`, `--st-done`,
  `--font-mono`) — those are scoped to the `.stride-screen` wrapper in
  `assets/css/app.css`. Do NOT substitute daisyUI base-* classes inside
  this component; the design's token vocabulary is canonical here.

  Also exposes `primary_full_button/1` (the ink primary button shape used
  by every auth CTA, mirroring `auth.jsx` PrimaryFullButton at lines
  190-209) and `sso_row/1` (Google/GitHub/SAML continue-with buttons,
  mirroring SSORow at lines 223-236).
  """

  use Phoenix.Component
  use Gettext, backend: KanbanWeb.Gettext

  use Phoenix.VerifiedRoutes,
    endpoint: KanbanWeb.Endpoint,
    router: KanbanWeb.Router,
    statics: KanbanWeb.static_paths()

  @valid_quote_keys [:signin, :signup, :forgot, :magic, :twofa]

  attr :quote_key, :atom,
    default: :signin,
    doc:
      "Which editorial quote to display in the left brand panel. " <>
        "One of :signin, :signup, :forgot, :magic, :twofa. " <>
        "Unknown values fall back to :signin."

  slot :footer_switch,
    doc: "Top-right cross-state link (e.g., 'New to Stride? Create an account →')."

  slot :inner_block, required: true, doc: "Form column content."

  def auth_frame(assigns) do
    assigns = assign(assigns, :quote, auth_quote(assigns.quote_key))

    ~H"""
    <div
      class="stride-screen"
      style="display: flex; min-height: 100vh; background: var(--bg);"
    >
      <aside
        class="hidden md:flex"
        style={[
          "width: 40%; min-width: 360px;",
          "background: linear-gradient(155deg, oklch(96% 0.025 60) 0%, oklch(94% 0.035 280) 100%);",
          "border-right: 1px solid var(--line);",
          "padding: 40px 40px 32px;",
          "flex-direction: column; position: relative;",
          "overflow: hidden;"
        ]}
      >
        <div style={[
          "position: absolute; right: -120px; top: 60px; width: 360px; height: 360px;",
          "border-radius: 50%; filter: blur(80px); opacity: 0.4;",
          "background: radial-gradient(circle, var(--stride-orange) 0%, transparent 70%);",
          "pointer-events: none;"
        ]}>
        </div>
        <div style={[
          "position: absolute; left: -60px; bottom: -80px; width: 320px; height: 320px;",
          "border-radius: 50%; filter: blur(90px); opacity: 0.3;",
          "background: radial-gradient(circle, var(--stride-violet) 0%, transparent 70%);",
          "pointer-events: none;"
        ]}>
        </div>

        <div style="display: flex; align-items: center; gap: 10px; position: relative;">
          <span style={[
            "width: 30px; height: 30px; border-radius: 8px;",
            "background: linear-gradient(135deg, var(--stride-orange) 0%, var(--stride-violet) 100%);",
            "display: inline-flex; align-items: center; justify-content: center;",
            "color: white; font-size: 15px; font-weight: 700; letter-spacing: -0.02em;",
            "box-shadow: 0 4px 14px rgba(0, 0, 0, 0.08);"
          ]}>
            S
          </span>
          <span style="font-weight: 600; font-size: 17px; letter-spacing: -0.02em;">
            Stride
          </span>
        </div>

        <span style="flex: 1;"></span>

        <div style="position: relative; max-width: 420px;">
          <span style={[
            "font-size: 72px; line-height: 0.6; color: var(--stride-orange);",
            "display: block; font-family: Georgia, serif; opacity: 0.4;",
            "margin-bottom: 8px;"
          ]}>
            &ldquo;
          </span>
          <p style={[
            "margin: 0; font-size: 22px; font-weight: 500; letter-spacing: -0.015em;",
            "line-height: 1.35; color: var(--ink); text-wrap: balance;"
          ]}>
            {@quote.line}
          </p>
          <p style={[
            "margin: 14px 0 0; font-size: 12px;",
            "color: var(--ink-3); letter-spacing: 0.02em;"
          ]}>
            {@quote.by}
          </p>
        </div>

        <span style="flex: 1;"></span>

        <div style={[
          "display: flex; align-items: center; gap: 14px;",
          "font-size: 11.5px; color: var(--ink-3); position: relative;"
        ]}>
          <span>&copy; {DateTime.utc_now().year} Stride</span>
          <span>&middot;</span>
          <.link
            navigate={~p"/privacy"}
            style="color: var(--ink-3); text-decoration: none;"
          >
            {gettext("Privacy")}
          </.link>
          <.link
            navigate={~p"/privacy"}
            style="color: var(--ink-3); text-decoration: none;"
          >
            {gettext("Terms")}
          </.link>
          <.link
            navigate={~p"/security"}
            style="color: var(--ink-3); text-decoration: none;"
          >
            {gettext("Security")}
          </.link>
          <span style="flex: 1;"></span>
          <span style={[
            "display: inline-flex; align-items: center; gap: 4px;",
            "color: var(--st-done);"
          ]}>
            <span style="width: 6px; height: 6px; border-radius: 50%; background: currentColor;">
            </span>
            {gettext("All systems normal")}
          </span>
        </div>
      </aside>

      <main
        class="px-5 md:px-10"
        style={[
          "flex: 1; display: flex; flex-direction: column;",
          "padding-top: 24px; padding-bottom: 24px;"
        ]}
      >
        <div style={[
          "display: flex; align-items: center; gap: 8px;",
          "font-size: 12px; color: var(--ink-3);"
        ]}>
          <span style="flex: 1;"></span>
          {render_slot(@footer_switch)}
        </div>

        <div style={[
          "flex: 1; display: flex; align-items: center; justify-content: center;"
        ]}>
          <div style={[
            "width: 100%; max-width: 440px;",
            "display: flex; flex-direction: column;"
          ]}>
            {render_slot(@inner_block)}
          </div>
        </div>
      </main>
    </div>
    """
  end

  @doc """
  Ink primary button matching `auth.jsx` PrimaryFullButton (lines 190-209).

  Renders a 40-tall dark-ink button with white text, optional leading
  spinner, and an optional trailing keyboard-shortcut chip. The button
  has no `type` attribute by default — pass `type="submit"` (or omit
  inside a `<.form>`) for form-submit behaviour. Pass `phx-disable-with`
  and other LiveView attributes via the global `:rest`.

  ## Examples

      <.primary_full_button kbd="↵" type="submit">Sign in</.primary_full_button>
      <.primary_full_button loading>Verifying…</.primary_full_button>
  """
  attr :kbd, :string,
    default: nil,
    doc: "Optional keyboard-shortcut chip rendered after the label."

  attr :loading, :boolean, default: false, doc: "When true, renders a leading spinner."
  attr :rest, :global, include: ~w(type name value form phx-disable-with phx-click disabled)
  slot :inner_block, required: true

  def primary_full_button(assigns) do
    ~H"""
    <button
      style={[
        "height: 40px; border-radius: 6px;",
        "background: var(--ink); color: white; border: none;",
        "font-size: 13.5px; font-weight: 500; letter-spacing: -0.005em;",
        "display: inline-flex; align-items: center; justify-content: center; gap: 8px;",
        "box-shadow: 0 1px 0 rgba(255, 255, 255, 0.1) inset, 0 1px 3px rgba(0, 0, 0, 0.2);",
        "cursor: pointer; width: 100%;"
      ]}
      {@rest}
    >
      <span
        :if={@loading}
        style={[
          "width: 12px; height: 12px; border-radius: 50%;",
          "border: 1.5px solid rgba(255, 255, 255, 0.35);",
          "border-top-color: white;",
          "animation: authspin 0.8s linear infinite;"
        ]}
      >
      </span>
      {render_slot(@inner_block)}
      <span
        :if={@kbd}
        style={[
          "font-family: var(--font-mono); font-size: 10.5px;",
          "padding: 1px 5px; background: rgba(255, 255, 255, 0.14);",
          "border-radius: 3px; margin-left: 4px;"
        ]}
      >
        {@kbd}
      </span>
    </button>
    """
  end

  @doc """
  Continue-with-provider button matching `auth.jsx` SSORow (lines 223-236).

  Renders a 38-tall white-surface button with a leading provider glyph
  and "Continue with <provider>" label. Three providers are wired up:
  `:google`, `:github`, `:saml`.

  ## Examples

      <.sso_row provider={:google} />
      <.sso_row provider={:github} />
      <.sso_row provider={:saml} />
  """
  attr :provider, :atom, required: true, values: [:google, :github, :saml]
  attr :rest, :global, include: ~w(type name value form phx-click disabled)

  def sso_row(assigns) do
    ~H"""
    <button
      type="button"
      style={[
        "height: 38px; border-radius: 6px;",
        "background: var(--surface); border: 1px solid var(--line-strong);",
        "font-size: 12.5px; font-weight: 500; color: var(--ink);",
        "display: inline-flex; align-items: center; justify-content: center; gap: 10px;",
        "cursor: pointer; width: 100%;"
      ]}
      {@rest}
    >
      <span style={["display: inline-flex; color: " <> sso_glyph_color(@provider) <> ";"]}>
        {sso_glyph(@provider)}
      </span>
      {sso_label(@provider)}
    </button>
    """
  end

  # -------------------------------------------------------------------------
  # Quote data (gettext-wrapped to support locales)
  # -------------------------------------------------------------------------

  defp auth_quote(key) when key in @valid_quote_keys, do: do_auth_quote(key)
  defp auth_quote(_), do: do_auth_quote(:signin)

  defp do_auth_quote(:signin) do
    %{
      line: gettext("Agents finally have somewhere good to work."),
      by: gettext("Jamie K · Engineering Lead, letstango.ca")
    }
  end

  defp do_auth_quote(:signup) do
    %{
      line: gettext("We replaced our backlog with Stride and shipped 38%% more in Q2."),
      by: gettext("Mei L · CTO, Carafe")
    }
  end

  defp do_auth_quote(:forgot) do
    %{
      line: gettext("A task structure that AI agents can actually pull from."),
      by: gettext("Rohan S · Infra, Stride")
    }
  end

  defp do_auth_quote(:magic) do
    %{
      line: gettext("Tokens rotate, claims survive. That alone was worth the switch."),
      by: gettext("Dani O · Platform, Stride")
    }
  end

  defp do_auth_quote(:twofa) do
    %{
      line: gettext("Security model is built for agents, not retrofitted for them."),
      by: gettext("Mei L · CTO, Carafe")
    }
  end

  # -------------------------------------------------------------------------
  # SSO glyphs — inline SVG matching `auth.jsx` SSO_GLYPHS (lines 238-258)
  # -------------------------------------------------------------------------

  defp sso_label(:google), do: gettext("Continue with %{provider}", provider: "Google")
  defp sso_label(:github), do: gettext("Continue with %{provider}", provider: "GitHub")
  defp sso_label(:saml), do: gettext("Continue with %{provider}", provider: "SSO (SAML)")

  defp sso_glyph_color(:google), do: ""
  defp sso_glyph_color(:github), do: "var(--ink)"
  defp sso_glyph_color(:saml), do: "var(--ink-2)"

  defp sso_glyph(:google) do
    assigns = %{}

    ~H"""
    <svg width="16" height="16" viewBox="0 0 16 16" xmlns="http://www.w3.org/2000/svg">
      <path
        d="M15.5 8.18c0-.52-.05-1.02-.13-1.5H8v2.85h4.2c-.18.97-.73 1.8-1.55 2.35v1.95h2.5c1.46-1.35 2.3-3.34 2.3-5.65z"
        fill="#4285F4"
      />
      <path
        d="M8 16c2.1 0 3.86-.7 5.15-1.88l-2.5-1.95c-.7.47-1.6.75-2.65.75-2.03 0-3.76-1.37-4.37-3.22H1.04v2.02C2.33 14.32 4.97 16 8 16z"
        fill="#34A853"
      />
      <path
        d="M3.63 9.7c-.16-.47-.25-.97-.25-1.7s.09-1.23.25-1.7V4.28H1.04C.38 5.45 0 6.68 0 8s.38 2.55 1.04 3.72L3.63 9.7z"
        fill="#FBBC05"
      />
      <path
        d="M8 3.18c1.14 0 2.17.4 2.98 1.16l2.22-2.22C11.86.94 10.1 0 8 0 4.97 0 2.33 1.68 1.04 4.28L3.63 6.3C4.24 4.55 5.97 3.18 8 3.18z"
        fill="#EA4335"
      />
    </svg>
    """
  end

  defp sso_glyph(:github) do
    assigns = %{}

    ~H"""
    <svg
      width="16"
      height="16"
      viewBox="0 0 16 16"
      fill="currentColor"
      xmlns="http://www.w3.org/2000/svg"
    >
      <path d="M8 0a8 8 0 0 0-2.53 15.59c.4.07.55-.17.55-.38v-1.4c-2.22.48-2.69-1.07-2.69-1.07-.36-.93-.89-1.18-.89-1.18-.73-.5.06-.49.06-.49.8.06 1.23.83 1.23.83.72 1.23 1.88.87 2.34.67.07-.52.28-.87.5-1.07-1.77-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.13 0 0 .67-.21 2.2.82a7.6 7.6 0 0 1 4 0c1.53-1.03 2.2-.82 2.2-.82.44 1.11.16 1.93.08 2.13.51.56.82 1.28.82 2.15 0 3.07-1.87 3.74-3.65 3.94.29.25.54.74.54 1.5v2.22c0 .21.15.46.55.38A8 8 0 0 0 8 0z" />
    </svg>
    """
  end

  defp sso_glyph(:saml) do
    assigns = %{}

    ~H"""
    <svg
      width="16"
      height="16"
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      stroke-width="1.5"
      stroke-linecap="round"
      stroke-linejoin="round"
      xmlns="http://www.w3.org/2000/svg"
    >
      <rect x="2" y="6" width="12" height="8" rx="1.5" />
      <path d="M5 6V4a3 3 0 0 1 6 0v2" />
    </svg>
    """
  end
end
