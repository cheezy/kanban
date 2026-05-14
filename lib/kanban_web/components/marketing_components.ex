defmodule KanbanWeb.MarketingComponents do
  @moduledoc """
  Function components used on the public marketing surfaces (the landing page,
  the about page, etc.). They reference the Stride design tokens defined in
  `assets/css/app.css` under the `.stride-marketing` scope — render any
  marketing component inside an element carrying that class so the tokens
  (`--ink`, `--ink-2`, `--line`, `--stride-orange`, `--stride-violet`, ...)
  resolve.

  These are the codebase counterpart to the React design references under
  `design_handoff_stride/design_source/screens/`. Treat that JSX as Figma —
  read it, mirror it, do not import it.
  """
  use KanbanWeb, :html

  import KanbanWeb.MarketingMiniBoard

  @doc """
  Renders the top navigation bar used on the landing page.

  Mirrors `MktNav` from `design_handoff_stride/design_source/screens/landing.jsx`.

  ## Auth state

    * Unauthenticated (`current_scope` is `nil`) → renders a "Sign in" link and
      a dark "Start free" pill button.
    * Authenticated → renders a single dark "Go to boards" pill button.

  ## Examples

      <.marketing_nav current_scope={@current_scope} />
  """
  attr :current_scope, :map,
    default: nil,
    doc: "The `@current_scope` assign — `nil` when no user is signed in."

  def marketing_nav(assigns) do
    ~H"""
    <nav
      class="flex items-center gap-6 h-14 px-9"
      style="border-bottom: 1px solid var(--line);"
    >
      <.link href={~p"/"} class="flex items-center gap-2">
        <span
          class="inline-flex items-center justify-center rounded-md text-white text-xs font-bold"
          style="width: 22px; height: 22px; background: linear-gradient(135deg, var(--stride-orange) 0%, var(--stride-violet) 100%); letter-spacing: -0.02em;"
        >
          S
        </span>
        <span class="text-sm font-semibold" style="letter-spacing: -0.015em;">
          {gettext("Stride")}
        </span>
      </.link>

      <span class="hidden md:inline-block w-px" style="height: 18px; background: var(--line);"></span>

      <div
        class="hidden md:flex items-center gap-[18px] text-[13px]"
        style="color: var(--ink-2);"
      >
        <.link href="#product" class="hover:opacity-70 transition-opacity">
          {gettext("Product")}
        </.link>
        <.link href="#workflows" class="hover:opacity-70 transition-opacity">
          {gettext("Workflows")}
        </.link>
        <.link href="#pricing" class="hover:opacity-70 transition-opacity">
          {gettext("Pricing")}
        </.link>
        <.link
          href={~p"/resources"}
          class="inline-flex items-center gap-[3px] hover:opacity-70 transition-opacity"
          title={gettext("API · Docs · Changelog")}
        >
          {gettext("Resources")}
          <.icon name="hero-chevron-down" class="w-2 h-2" />
        </.link>
        <.link href={~p"/about"} class="hover:opacity-70 transition-opacity">
          {gettext("About")}
        </.link>
      </div>

      <span class="flex-1"></span>

      <%= if @current_scope do %>
        <.link
          href={~p"/boards"}
          class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-md text-xs font-medium text-white hover:opacity-90 transition-opacity"
          style="background: var(--ink);"
        >
          {gettext("Go to boards")}
          <.icon name="hero-arrow-right" class="w-3 h-3" />
        </.link>
      <% else %>
        <.link
          href={~p"/users/log-in"}
          class="text-[13px] hover:opacity-70 transition-opacity"
          style="color: var(--ink-2);"
        >
          {gettext("Sign in")}
        </.link>
        <.link
          href={~p"/users/register"}
          class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-md text-xs font-medium text-white hover:opacity-90 transition-opacity"
          style="background: var(--ink);"
        >
          {gettext("Start free")}
          <.icon name="hero-arrow-right" class="w-3 h-3" />
        </.link>
      <% end %>
    </nav>
    """
  end

  @doc """
  Renders the landing-page hero — release pill, two-tone headline, sub-copy,
  primary + secondary CTAs, microcopy, and the realistic `marketing_mini_board`
  showing live-looking task cards.

  Mirrors the hero section of `Landing_Editorial` in
  `design_handoff_stride/design_source/screens/landing.jsx` (lines ~149-199).

  ## Auth state

    * Unauthenticated → primary CTA is "Start free" linking to `~p"/users/register"`.
    * Authenticated   → primary CTA becomes "Go to my boards" linking to `~p"/boards"`.

  ## Examples

      <.marketing_hero current_scope={@current_scope} />
  """
  attr :current_scope, :map,
    default: nil,
    doc: "The `@current_scope` assign — `nil` when no user is signed in."

  def marketing_hero(assigns) do
    ~H"""
    <section class="px-16 pt-20 pb-14" style="border-bottom: 1px solid var(--line);">
      <div class="flex items-center gap-2 mb-6">
        <span
          class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-[11px] font-medium"
          style="background: var(--stride-violet-soft); color: var(--stride-violet-ink);"
        >
          <.icon name="hero-sparkles" class="w-2.5 h-2.5" />
          {gettext("v2.4 · Atomic claims w/ capability matching")}
        </span>
        <span class="text-xs" style="color: var(--ink-3);">
          {gettext("Now in beta →")}
        </span>
      </div>

      <h1
        class="m-0 font-semibold"
        style="font-size: clamp(40px, 6vw, 72px); letter-spacing: -0.04em; line-height: 0.98; max-width: 1100px; color: var(--ink); text-wrap: pretty;"
      >
        {gettext("Tasks are conversations.")}
        <br />
        <span style="color: var(--ink-4);">
          {gettext("Your kanban can speak both ways.")}
        </span>
      </h1>

      <p
        class="mt-6"
        style="max-width: 620px; font-size: 17.5px; line-height: 1.5; color: var(--ink-2); text-wrap: pretty;"
      >
        {gettext(
          "Stride is an AI-native kanban. Humans plan, review, and approve. Agents claim, build, and ship. Same board. One workflow. No glue code."
        )}
      </p>

      <div class="flex flex-wrap items-center gap-3.5 mt-8">
        <%= if @current_scope do %>
          <.link
            href={~p"/boards"}
            class="inline-flex items-center gap-1.5 px-4 py-2.5 rounded-md text-sm font-medium text-white hover:opacity-90 transition-opacity"
            style="background: var(--ink);"
          >
            {gettext("Go to my boards")}
            <.icon name="hero-arrow-right" class="w-3 h-3" />
          </.link>
        <% else %>
          <.link
            href={~p"/users/register"}
            class="inline-flex items-center gap-1.5 px-4 py-2.5 rounded-md text-sm font-medium text-white hover:opacity-90 transition-opacity"
            style="background: var(--ink);"
          >
            {gettext("Start free")}
            <.icon name="hero-arrow-right" class="w-3 h-3" />
          </.link>
        <% end %>

        <.link
          href={~p"/resources"}
          class="inline-flex items-center gap-1.5 px-4 py-2.5 rounded-md text-sm font-medium hover:opacity-90 transition-opacity"
          style="background: transparent; color: var(--ink); border: 1px solid var(--line-strong);"
        >
          <.icon name="hero-cpu-chip" class="w-3 h-3" />
          {gettext("Read the agent API")}
        </.link>

        <span
          class="inline-flex items-center gap-1.5 ml-1.5 text-xs"
          style="color: var(--ink-3);"
        >
          <.icon name="hero-check" class="w-2.5 h-2.5" />
          {gettext("Free for solo · self-host on day one")}
        </span>
      </div>

      <div class="mt-16" style="max-width: 1200px;">
        <.marketing_mini_board />
      </div>
    </section>
    """
  end

  @doc """
  Renders the editorial belief-band section: a two-column grid with the
  product reframe headline on the left and two body paragraphs on the right.

  Mirrors lines ~202-224 of `landing.jsx`.

  ## Examples

      <.marketing_belief_band />
  """
  def marketing_belief_band(assigns) do
    ~H"""
    <section class="px-16 py-16" style="border-bottom: 1px solid var(--line); padding-bottom: 56px;">
      <div
        class="grid gap-20 items-baseline"
        style="grid-template-columns: 1.2fr 1fr;"
      >
        <div>
          <span class="ucase">{gettext("A new contract")}</span>
          <h2
            class="font-semibold"
            style="margin: 12px 0 0; font-size: 40px; letter-spacing: -0.03em; line-height: 1.1; text-wrap: pretty;"
          >
            {gettext("AI agents are first-class teammates,")}
            <br />
            <span style="color: var(--stride-orange);">
              {gettext("not bots you babysit.")}
            </span>
          </h2>
        </div>
        <div
          class="flex flex-col"
          style="gap: 22px; font-size: 14.5px; line-height: 1.6; color: var(--ink-2); text-wrap: pretty;"
        >
          <p style="margin: 0;">
            {gettext(
              "Most tools bolt AI on as a sidebar. Stride was built around the protocol agents need: atomic claims, capability matching, structured task context, and client-side hooks they fully control."
            )}
          </p>
          <p style="margin: 0;">
            {gettext(
              "Humans get a fast, calm board to plan and review. Agents get an API rich enough to ship without asking. The same board feels native to both."
            )}
          </p>
        </div>
      </div>
    </section>
    """
  end

  @doc """
  Renders the 4-step "How it works" section: a ucase label + microcopy, then a
  bordered 4-column grid (each cell carries a mono step number, an icon in a
  tinted square, a title, and body copy).

  Mirrors lines ~227-282 of `landing.jsx`.

  ## Examples

      <.marketing_how_it_works />
  """
  def marketing_how_it_works(assigns) do
    assigns = assign(assigns, :steps, how_it_works_steps())

    ~H"""
    <section class="px-16 pt-16 pb-8">
      <div class="flex items-baseline gap-3.5 mb-9">
        <span class="ucase">{gettext("How it works")}</span>
        <span class="text-[13px]" style="color: var(--ink-3);">
          {gettext("One loop. Two roles.")}
        </span>
      </div>

      <div
        class="grid overflow-hidden"
        style="grid-template-columns: repeat(4, 1fr); gap: 0; border: 1px solid var(--line); border-radius: 12px;"
      >
        <div
          :for={{step, index} <- Enum.with_index(@steps)}
          class="flex flex-col gap-3"
          style={[
            "padding: 24px 22px 26px; background: var(--surface);",
            if(index < 3, do: " border-right: 1px solid var(--line);", else: "")
          ]}
        >
          <div class="flex items-center gap-2.5">
            <span style="font-family: var(--font-mono); font-size: 11px; color: var(--ink-4); font-weight: 500;">
              {step.number}
            </span>
            <span class="flex-1"></span>
            <span
              class="inline-flex items-center justify-center"
              style={"width: 26px; height: 26px; border-radius: 6px; background: var(--surface-sunken); color: #{step.color};"}
            >
              <.icon name={step.icon} class="w-3 h-3" />
            </span>
          </div>
          <h3 class="font-semibold" style="margin: 0; font-size: 17px; letter-spacing: -0.015em;">
            {step.title}
          </h3>
          <p style="margin: 0; font-size: 13px; line-height: 1.55; color: var(--ink-2); text-wrap: pretty;">
            {step.body}
          </p>
        </div>
      </div>
    </section>
    """
  end

  defp how_it_works_steps do
    [
      %{
        number: "01",
        title: gettext("You write the task"),
        body:
          gettext(
            "Why, what, where, acceptance criteria, key files, hooks. The schema is the conversation."
          ),
        icon: "hero-sparkles",
        color: "var(--ink)"
      },
      %{
        number: "02",
        title: gettext("An agent claims it"),
        body:
          gettext(
            "Atomic. SKIP LOCKED. Only one agent gets it. They pull latest, set up, then implement."
          ),
        icon: "hero-cpu-chip",
        color: "var(--st-doing)"
      },
      %{
        number: "03",
        title: gettext("Hooks run on their machine"),
        body:
          gettext(
            "mix test, gh pr create, whatever you put in .stride.md. You hold the keys; agents hold the loop."
          ),
        icon: "hero-bolt",
        color: "var(--stride-orange)"
      },
      %{
        number: "04",
        title: gettext("You approve or send back"),
        body:
          gettext(
            "Diff, tests, acceptance — all in one pane. ⌘A approves and runs after_review. Done."
          ),
        icon: "hero-check",
        color: "var(--st-done)"
      }
    ]
  end
end
