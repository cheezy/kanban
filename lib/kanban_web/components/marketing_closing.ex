defmodule KanbanWeb.MarketingClosing do
  @moduledoc """
  Bottom-of-page marketing components for the landing page: the lower CTA
  and the footer. Lives in its own module so the parent
  `KanbanWeb.MarketingComponents` stays under the 500-line guideline.

  Mirrors lines ~347-391 of
  `design_handoff_stride/design_source/screens/landing.jsx`.

  Render inside the `.stride-marketing` CSS scope so the design tokens
  (`--ink`, `--ink-2`, `--ink-3`, `--line`, `--stride-orange`,
  `--stride-violet`, `--surface`, `--line-strong`) resolve.
  """
  use KanbanWeb, :html

  @doc """
  Renders the lower CTA section: large two-line headline with orange emphasis on
  "approving them.", sub-copy, and a single centered dark "Start free" CTA
  (swaps to "Go to my boards" when the user is signed in).

  Mirrors lines ~347-371 of `landing.jsx`.

  ## Examples

      <.marketing_cta_section current_scope={@current_scope} />
  """
  attr :current_scope, :map,
    default: nil,
    doc: "The `@current_scope` assign — `nil` when no user is signed in."

  def marketing_cta_section(assigns) do
    ~H"""
    <section class="px-5 pt-12 pb-14 md:px-16 md:pt-16 md:pb-20 text-center">
      <h2
        class="font-semibold"
        style="margin: 0; font-size: clamp(28px, 5vw, 44px); letter-spacing: -0.035em; line-height: 1.05; text-wrap: pretty;"
      >
        {gettext("Stop writing every line.")}
        <br />
        {gettext("Start")}
        <span style="color: var(--stride-orange-ink);">
          {gettext("approving them.")}
        </span>
      </h2>
      <p style="margin: 14px auto 0; font-size: 15px; color: var(--ink-2); max-width: 540px;">
        {gettext(
          "Free for you and your teams. Bring any agent — Claude, Copilot, Gemini, Codex, OpenCode, your own."
        )}
      </p>
      <div class="flex flex-col md:flex-row md:justify-center gap-3 mt-5 md:mt-[22px]">
        <%= if @current_scope do %>
          <.link
            href={~p"/boards"}
            class="inline-flex items-center justify-center gap-1.5 font-medium hover:opacity-90 transition-opacity h-12 md:h-11 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
            style="padding: 12px 22px; border-radius: 7px; background: var(--ink); color: var(--surface); font-size: 14px;"
          >
            {gettext("Go to my boards")}
            <.icon name="hero-arrow-right" class="w-3 h-3" />
          </.link>
        <% else %>
          <.link
            href={~p"/users/register"}
            class="inline-flex items-center justify-center gap-1.5 font-medium hover:opacity-90 transition-opacity h-12 md:h-11 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
            style="padding: 12px 22px; border-radius: 7px; background: var(--ink); color: var(--surface); font-size: 14px;"
          >
            {gettext("Start free")}
            <.icon name="hero-arrow-right" class="w-3 h-3" />
          </.link>
        <% end %>
      </div>
    </section>
    """
  end

  @doc """
  Renders the landing-page footer: gradient logo + wordmark + domain +
  copyright on the left, right-aligned legal links on the right.

  Mirrors lines ~374-391 of `landing.jsx`.

  ## Examples

      <.marketing_footer />
  """
  def marketing_footer(assigns) do
    ~H"""
    <footer
      class="flex flex-col md:flex-row md:items-center gap-4 md:gap-7 px-5 py-6 md:px-16 md:py-8"
      style="border-top: 1px solid var(--line); font-size: 12px; color: var(--ink-3);"
    >
      <div class="flex items-center gap-2">
        <img
          src={~p"/images/logos/abstract-s-motion.svg"}
          alt={gettext("Stride logo")}
          class="w-5 h-5"
        />
        <span style="font-weight: 500; color: var(--ink-2);">{gettext("Stride")}</span>
        <span>· StrideLikeABoss.com</span>
      </div>
      <span class="md:inline">© 2026</span>
      <span class="hidden md:inline flex-1"></span>
      <div class="flex flex-wrap gap-4 md:gap-7">
        <.link
          href={~p"/privacy"}
          class="hover:opacity-70 transition-opacity focus-visible:opacity-70 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
        >
          {gettext("Privacy")}
        </.link>
        <.link
          href={~p"/security"}
          class="hover:opacity-70 transition-opacity focus-visible:opacity-70 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
        >
          {gettext("Security")}
        </.link>
        <.link
          href="https://github.com/cheezy/kanban"
          target="_blank"
          rel="noopener noreferrer"
          class="hover:opacity-70 transition-opacity focus-visible:opacity-70 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
        >
          {gettext("GitHub")}
        </.link>
      </div>
    </footer>
    """
  end
end
