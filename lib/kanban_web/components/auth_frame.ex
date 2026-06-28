defmodule KanbanWeb.AuthFrame do
  @moduledoc """
  Centered auth shell. Every auth surface (sign in, sign up, forgot/reset
  password, confirmation) renders inside `auth_frame/1`: a single centered
  column holding the Stride wordmark, an optional top cross-state link
  (`footer_switch`, e.g. "New to Stride? Create an account →"), and the form
  (`inner_block`).

  **Theme-aware.** The frame follows the active theme — light on light, dark
  on dark — using the Stride design tokens (`--ink`, `--surface`, `--line`,
  `--stride-orange`, `--stride-violet`, `--font-mono`) scoped to the
  `.stride-screen` wrapper in `assets/css/app.css`. Do NOT substitute daisyUI
  base-* classes inside this component; the design's token vocabulary is
  canonical here.

  Also exposes `primary_full_button/1` (the inverted "ink" primary button —
  dark fill in light mode, light fill in dark mode, with a `var(--surface)`
  label so it stays legible in both themes).
  """

  use Phoenix.Component
  use Gettext, backend: KanbanWeb.Gettext

  use Phoenix.VerifiedRoutes,
    endpoint: KanbanWeb.Endpoint,
    router: KanbanWeb.Router,
    statics: KanbanWeb.static_paths()

  attr :flash, :map,
    default: %{},
    doc: "Flash map from the LiveView (`@flash`). Renders :error and :info banners."

  slot :footer_switch,
    doc:
      "Cross-state link shown next to the wordmark (e.g., 'New to Stride? Create an account →')."

  slot :inner_block, required: true, doc: "Form column content."

  def auth_frame(assigns) do
    ~H"""
    <div
      class="stride-screen"
      style="min-height: 100vh; min-height: 100dvh; display: flex; align-items: center; justify-content: center; background: var(--bg); padding: 32px 20px;"
    >
      <div
        data-auth-frame
        style="width: 100%; max-width: 440px; display: flex; flex-direction: column;"
      >
        <%!-- Wordmark + cross-state link. flex-wrap + space-between keeps them on
              one row on desktop and lets the cross-state link drop to its own
              line on narrow phones instead of overflowing. --%>
        <div style="display: flex; flex-wrap: wrap; align-items: center; justify-content: flex-end; gap: 8px 12px; margin-bottom: 32px;">
          <div style="font-size: 12px; color: var(--ink-3);">
            {render_slot(@footer_switch)}
          </div>
        </div>

        <%!-- Flash banners. The --st-* token pairs are contrast-verified in both
              themes by mix dark_mode.contrast, keeping the frame's no-daisyUI
              contract intact. --%>
        <p
          :if={Phoenix.Flash.get(@flash, :error)}
          id="auth-flash-error"
          role="alert"
          style="margin: 0 0 16px; padding: 10px 12px; border-radius: 6px; font-size: 13px; line-height: 1.45; background: var(--st-blocked-soft); color: var(--st-blocked);"
        >
          {Phoenix.Flash.get(@flash, :error)}
        </p>
        <p
          :if={Phoenix.Flash.get(@flash, :info)}
          id="auth-flash-info"
          role="status"
          style="margin: 0 0 16px; padding: 10px 12px; border-radius: 6px; font-size: 13px; line-height: 1.45; background: var(--st-done-soft); color: var(--st-done);"
        >
          {Phoenix.Flash.get(@flash, :info)}
        </p>

        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  Inverted "ink" primary button.

  Renders a 40-tall button (raised to a 44px minimum touch target below the
  `md` breakpoint via the `[data-auth-frame]` rule in `app.css`) filled with
  `var(--ink)` (so it is dark in light mode and light in dark mode) and
  labelled with `var(--surface)` so the text stays legible in both themes.
  Supports an optional leading spinner and a trailing keyboard-shortcut chip.
  The button has no `type` attribute by default — pass `type="submit"` (or omit
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
        "background: var(--ink); color: var(--surface); border: none;",
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
          "border-top-color: var(--surface);",
          "animation: authspin 0.8s linear infinite;"
        ]}
      ></span>
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
end
