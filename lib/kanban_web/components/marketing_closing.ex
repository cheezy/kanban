defmodule KanbanWeb.MarketingClosing do
  @moduledoc """
  Bottom-of-page marketing components for the landing page: the numbers band,
  the lower CTA, and the footer. Lives in its own module so the parent
  `KanbanWeb.MarketingComponents` stays under the 500-line guideline.

  Mirrors lines ~327-391 of
  `design_handoff_stride/design_source/screens/landing.jsx`.

  Render inside the `.stride-marketing` CSS scope so the design tokens
  (`--ink`, `--ink-2`, `--ink-3`, `--line`, `--stride-orange`,
  `--stride-violet`, `--surface`, `--line-strong`) resolve.
  """
  use KanbanWeb, :html

  @doc """
  Renders the 4-column numbers band. Tabular numerals so the values line up.

  Mirrors lines ~327-344 of `landing.jsx`.

  ## Examples

      <.marketing_numbers_band />
  """
  def marketing_numbers_band(assigns) do
    assigns = assign(assigns, :metrics, numbers_band_metrics())

    ~H"""
    <section
      class="px-5 py-10 md:px-16 md:py-14"
      style="border-top: 1px solid var(--line); border-bottom: 1px solid var(--line); background: var(--surface);"
    >
      <div class="grid grid-cols-2 md:grid-cols-4 gap-6 md:gap-9">
        <div :for={metric <- @metrics} class="flex flex-col gap-1">
          <span
            class="font-semibold"
            style={"font-size: clamp(28px, 5vw, 44px); letter-spacing: -0.035em; font-feature-settings: \"tnum\";"}
          >
            {metric.value}
          </span>
          <span style="font-size: 12.5px; color: var(--ink-3); text-wrap: pretty;">
            {metric.label}
          </span>
        </div>
      </div>
    </section>
    """
  end

  defp numbers_band_metrics do
    [
      %{value: "0.4s", label: gettext("Agent-to-task latency · p95")},
      %{value: "94.6%", label: gettext("Test coverage in core")},
      %{value: "17m", label: gettext("Median time to human review")},
      %{value: "23.6 / day", label: gettext("Tasks shipped per active board")}
    ]
  end

  @doc """
  Renders the lower CTA section: large two-line headline with orange emphasis on
  "approving them.", sub-copy, and two centered buttons (dark "Start free" and
  bordered "Talk to a human").

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
        <span style="color: var(--stride-orange);">
          {gettext("approving them.")}
        </span>
      </h2>
      <p style="margin: 14px auto 0; font-size: 15px; color: var(--ink-2); max-width: 540px;">
        {gettext(
          "Free for solo developers and small teams. Self-host the whole thing. Bring any agent — Claude, Cursor, Aider, Codex, your own."
        )}
      </p>
      <div class="flex flex-col md:flex-row md:justify-center gap-3 mt-5 md:mt-[22px]">
        <%= if @current_scope do %>
          <.link
            href={~p"/boards"}
            class="inline-flex items-center justify-center gap-1.5 text-white font-medium hover:opacity-90 transition-opacity h-12 md:h-auto"
            style="padding: 12px 22px; border-radius: 7px; background: var(--ink); font-size: 14px;"
          >
            {gettext("Go to my boards")}
            <.icon name="hero-arrow-right" class="w-3 h-3" />
          </.link>
        <% else %>
          <.link
            href={~p"/users/register"}
            class="inline-flex items-center justify-center gap-1.5 text-white font-medium hover:opacity-90 transition-opacity h-12 md:h-auto"
            style="padding: 12px 22px; border-radius: 7px; background: var(--ink); font-size: 14px;"
          >
            {gettext("Start free")}
            <.icon name="hero-arrow-right" class="w-3 h-3" />
          </.link>
        <% end %>
        <.link
          href={~p"/about"}
          class="inline-flex items-center justify-center font-medium hover:opacity-90 transition-opacity h-12 md:h-auto"
          style="padding: 12px 22px; border-radius: 7px; background: transparent; border: 1px solid var(--line-strong); color: var(--ink); font-size: 14px;"
        >
          {gettext("Talk to a human")}
        </.link>
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
        <.link href={~p"/tango"} class="hover:opacity-70 transition-opacity">
          {gettext("Privacy")}
        </.link>
        <.link href={~p"/tango"} class="hover:opacity-70 transition-opacity">
          {gettext("Security")}
        </.link>
        <.link href={~p"/changelog"} class="hover:opacity-70 transition-opacity">
          {gettext("Status")}
        </.link>
        <.link
          href="https://github.com/cheezy/kanban"
          target="_blank"
          rel="noopener noreferrer"
          class="hover:opacity-70 transition-opacity"
        >
          {gettext("GitHub")}
        </.link>
      </div>
    </footer>
    """
  end
end
