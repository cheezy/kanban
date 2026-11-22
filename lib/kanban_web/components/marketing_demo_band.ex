defmodule KanbanWeb.MarketingDemoBand do
  @moduledoc """
  The home page band that links to the public `/demo` replay
  (`KanbanWeb.DemoBoardLive`), so a visitor can watch agents work a board
  before signing up. Lives in its own module so
  `KanbanWeb.MarketingComponents` does not grow past the module-size
  guideline.

  Not in the landing design: the design has no demo. It takes the horizontal
  padding and bottom border of the belief band, with less vertical padding
  so the band reads as a short aside, and the outlined secondary button of
  the hero.

  Render inside the `.stride-marketing` CSS scope so the design tokens
  (`--ink`, `--ink-2`, `--line`, `--line-strong`) resolve.
  """
  use KanbanWeb, :html

  @doc "Renders the demo band: a heading, one sentence and a link to `/demo`."
  def marketing_demo_band(assigns) do
    ~H"""
    <section
      class="px-5 py-8 md:px-16 md:py-10 flex flex-col md:flex-row md:items-center gap-4 md:gap-10"
      style="border-bottom: 1px solid var(--line);"
      data-demo-band
    >
      <div class="flex flex-col gap-1.5 flex-1 min-w-0">
        <h2
          class="font-semibold"
          style="margin: 0; font-size: 20px; letter-spacing: -0.02em; line-height: 1.2;"
        >
          {gettext("See agents work a board")}
        </h2>
        <p style="margin: 0; font-size: 14.5px; line-height: 1.6; color: var(--ink-2); text-wrap: pretty;">
          {gettext(
            "Watch a replay of agents claiming tasks, running their hooks and moving cards to Done. No account needed."
          )}
        </p>
      </div>
      <.link
        navigate={~p"/demo"}
        class="inline-flex items-center gap-1.5 px-4 py-2.5 rounded-md text-sm font-medium hover:opacity-90 transition-opacity self-start md:self-auto"
        style="background: transparent; color: var(--ink); border: 1px solid var(--line-strong);"
        data-demo-link
      >
        <.icon name="hero-play" class="w-3 h-3" />
        {gettext("Watch a simulated demo")}
      </.link>
    </section>
    """
  end
end
