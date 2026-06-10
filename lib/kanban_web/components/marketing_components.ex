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

  alias KanbanWeb.NavComponents

  @doc """
  Renders the top navigation bar used on the landing page.

  Mirrors `MktNav` from `design_handoff_stride/design_source/screens/landing.jsx`.

  ## Auth state

    * Unauthenticated (`current_scope` is `nil`) → renders a "Sign in" link and
      a dark "Start now" pill button.
    * Authenticated → renders a single dark "Go to boards" pill button.

  ## Examples

      <.marketing_nav current_scope={@current_scope} />
  """
  attr :current_scope, :map,
    default: nil,
    doc: "The `@current_scope` assign — `nil` when no user is signed in."

  attr :current_locale, :string,
    default: "en",
    doc: "Active locale code (e.g. \"en\", \"fr\"). Drives the language switcher."

  def marketing_nav(assigns) do
    ~H"""
    <nav
      class="flex items-center gap-3 md:gap-6 h-14 px-4 md:px-9"
      style="border-bottom: 1px solid var(--line);"
    >
      <.link href={~p"/"} class="flex items-center gap-2">
        <img
          src={~p"/images/logos/abstract-s-motion.svg"}
          alt={gettext("Stride logo")}
          class="w-7 h-7"
        />
        <span class="text-sm font-semibold" style="letter-spacing: -0.015em;">
          {gettext("Stride")}
        </span>
      </.link>

      <span class="hidden md:inline-block w-px" style="height: 18px; background: var(--line);"></span>

      <div
        class="hidden md:flex items-center gap-[18px] text-[13px]"
        style="color: var(--ink-2);"
      >
        <.link href={~p"/product"} class="hover:opacity-70 transition-opacity">
          {gettext("Product")}
        </.link>
        <.link href={~p"/workflows"} class="hover:opacity-70 transition-opacity">
          {gettext("Workflows")}
        </.link>
        <.link
          :if={@current_scope && @current_scope.user.type == :admin}
          href={~p"/pricing"}
          class="hover:opacity-70 transition-opacity"
        >
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
        <%= if @current_scope.user.type == :admin do %>
          <.link
            href={~p"/admin/dashboard"}
            class="hidden md:inline-flex text-[13px] hover:opacity-70 transition-opacity"
            style="color: var(--ink-2);"
          >
            {gettext("Dashboard")}
          </.link>
          <.link
            href={~p"/admin/errors"}
            class="hidden md:inline-flex text-[13px] hover:opacity-70 transition-opacity"
            style="color: var(--ink-2);"
          >
            {gettext("Error Tracker")}
          </.link>
        <% end %>
        <.link
          href={~p"/users/log-out"}
          method="delete"
          class="hidden md:inline-flex text-[13px] hover:opacity-70 transition-opacity"
          style="color: var(--ink-2);"
        >
          {gettext("Sign out")}
        </.link>
        <.link
          href={~p"/boards"}
          class="inline-flex items-center gap-1.5 px-3 py-1.5 min-h-[44px] md:min-h-0 rounded-md text-xs font-medium hover:opacity-90 transition-opacity focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
          style="background: var(--ink); color: var(--surface);"
        >
          {gettext("Go to boards")}
          <.icon name="hero-arrow-right" class="w-3 h-3" />
        </.link>
      <% else %>
        <.link
          href={~p"/users/log-in"}
          class="hidden md:inline-flex text-[13px] hover:opacity-70 transition-opacity"
          style="color: var(--ink-2);"
        >
          {gettext("Sign in")}
        </.link>
        <.link
          href={~p"/users/register"}
          class="inline-flex items-center gap-1.5 px-3 py-1.5 min-h-[44px] md:min-h-0 rounded-md text-xs font-medium hover:opacity-90 transition-opacity focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
          style="background: var(--ink); color: var(--surface);"
        >
          {gettext("Start now")}
          <.icon name="hero-arrow-right" class="w-3 h-3" />
        </.link>
      <% end %>

      <.marketing_language_switcher current_locale={@current_locale} />

      <details class="md:hidden relative js-mobile-menu group">
        <summary
          class="list-none [&::-webkit-details-marker]:hidden [&::marker]:hidden inline-flex items-center justify-center w-11 h-11 rounded-md cursor-pointer hover:opacity-70 transition-opacity focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
          style="color: var(--ink-2);"
          aria-label={gettext("Toggle menu")}
          aria-controls="marketing-mobile-menu"
          aria-expanded="false"
        >
          <.icon name="hero-bars-3" class="w-5 h-5 group-open:hidden" />
          <.icon name="hero-x-mark" class="w-5 h-5 hidden group-open:block" />
        </summary>
        <div
          id="marketing-mobile-menu"
          class="absolute right-0 top-full mt-2 w-64 rounded-xl shadow-lg py-2 z-50"
          style="background: var(--surface); border: 1px solid var(--line); color: var(--ink-2);"
        >
          <.marketing_mobile_menu current_scope={@current_scope} />
        </div>
      </details>
    </nav>
    """
  end

  @doc false
  attr :current_locale, :string, required: true

  defp marketing_language_switcher(assigns) do
    assigns = assign(assigns, :locales, NavComponents.supported_locales())

    ~H"""
    <div
      class="relative hidden md:flex items-center"
      id="marketing-language-switcher"
      phx-hook="Dropdown"
    >
      <button
        type="button"
        data-dropdown-toggle
        class="inline-flex items-center gap-1.5 px-2 py-1 rounded-md text-[12.5px] hover:opacity-70 transition-opacity"
        style="color: var(--ink-2);"
        aria-label={gettext("Change language")}
      >
        <NavComponents.locale_flag locale={@current_locale} />
        <span style="font-family: var(--font-mono);">
          {String.upcase(@current_locale)}
        </span>
        <.icon name="hero-chevron-down" class="w-2.5 h-2.5" />
      </button>
      <div
        data-dropdown-menu
        class="hidden absolute top-full right-0 mt-1 py-1 z-50"
        style="background: var(--surface); border: 1px solid var(--line); border-radius: 6px; box-shadow: var(--shadow-md); min-width: 160px;"
      >
        <form
          :for={locale <- @locales}
          id={"marketing-locale-form-#{locale.code}"}
          action={~p"/locale/#{locale.code}"}
          method="post"
        >
          <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
          <button
            type="submit"
            class={[
              "flex items-center gap-2 w-full px-3 py-2 text-[13px] text-left transition-colors row-hover",
              if(@current_locale == locale.code,
                do: "font-medium",
                else: ""
              )
            ]}
            style={
              if(@current_locale == locale.code,
                do: "color: var(--stride-orange-ink); background: var(--stride-orange-soft);",
                else: "color: var(--ink-2);"
              )
            }
          >
            <NavComponents.locale_flag locale={locale.code} />
            <span>{locale.name}</span>
            <%= if @current_locale == locale.code do %>
              <.icon name="hero-check" class="w-3 h-3 ml-auto" />
            <% end %>
          </button>
        </form>
      </div>
    </div>
    """
  end

  @doc false
  attr :current_scope, :map, default: nil

  defp marketing_mobile_menu(assigns) do
    ~H"""
    <.link
      href={~p"/product"}
      class="flex items-center min-h-11 px-4 text-[14px] hover:opacity-70 transition-opacity focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-[-2px]"
    >
      {gettext("Product")}
    </.link>
    <.link
      href={~p"/workflows"}
      class="flex items-center min-h-11 px-4 text-[14px] hover:opacity-70 transition-opacity focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-[-2px]"
    >
      {gettext("Workflows")}
    </.link>
    <.link
      :if={@current_scope && @current_scope.user.type == :admin}
      href={~p"/pricing"}
      class="flex items-center min-h-11 px-4 text-[14px] hover:opacity-70 transition-opacity focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-[-2px]"
    >
      {gettext("Pricing")}
    </.link>
    <.link
      href={~p"/resources"}
      class="flex items-center min-h-11 px-4 text-[14px] hover:opacity-70 transition-opacity focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-[-2px]"
    >
      {gettext("Resources")}
    </.link>
    <.link
      href={~p"/about"}
      class="flex items-center min-h-11 px-4 text-[14px] hover:opacity-70 transition-opacity focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-[-2px]"
    >
      {gettext("About")}
    </.link>

    <hr class="my-2" style="border-color: var(--line);" />

    <%= if @current_scope do %>
      <%= if @current_scope.user.type == :admin do %>
        <.link
          href={~p"/admin/dashboard"}
          class="flex items-center min-h-11 px-4 text-[14px] hover:opacity-70 transition-opacity focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-[-2px]"
        >
          {gettext("Dashboard")}
        </.link>
        <.link
          href={~p"/admin/errors"}
          class="flex items-center min-h-11 px-4 text-[14px] hover:opacity-70 transition-opacity focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-[-2px]"
        >
          {gettext("Error Tracker")}
        </.link>
      <% end %>
      <.link
        href={~p"/users/log-out"}
        method="delete"
        class="flex items-center min-h-11 px-4 text-[14px] hover:opacity-70 transition-opacity focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-[-2px]"
      >
        {gettext("Sign out")}
      </.link>
    <% else %>
      <.link
        href={~p"/users/log-in"}
        class="flex items-center min-h-11 px-4 text-[14px] hover:opacity-70 transition-opacity focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-[-2px]"
      >
        {gettext("Sign in")}
      </.link>
    <% end %>
    """
  end

  @doc """
  Renders the landing-page hero — release pill, two-tone headline, sub-copy,
  primary + secondary CTAs, microcopy, and the realistic `marketing_mini_board`
  showing live-looking task cards.

  Mirrors the hero section of `Landing_Editorial` in
  `design_handoff_stride/design_source/screens/landing.jsx` (lines ~149-199).

  ## Auth state

    * Unauthenticated → primary CTA is "Start now" linking to `~p"/users/register"`.
    * Authenticated   → primary CTA becomes "Go to my boards" linking to `~p"/boards"`.

  ## Examples

      <.marketing_hero current_scope={@current_scope} />
  """
  attr :current_scope, :map,
    default: nil,
    doc: "The `@current_scope` assign — `nil` when no user is signed in."

  attr :has_boards, :boolean,
    default: false,
    doc:
      "True when the signed-in user has at least one board. Controls the secondary CTA: " <>
        "`false` → \"Learn about creating a board\"; `true` → \"Learn about adding team members\"."

  def marketing_hero(assigns) do
    ~H"""
    <section
      class="px-5 pt-10 pb-10 md:px-16 md:pt-20 md:pb-14"
      style="border-bottom: 1px solid var(--line);"
    >
      <div class="flex flex-wrap items-center gap-2 mb-6">
        <span
          class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-[11px] font-medium"
          style="background: var(--stride-violet-soft); color: var(--stride-violet-ink);"
        >
          <.icon name="hero-sparkles" class="w-2.5 h-2.5" /> v2.3.0 · Strict completion validation
        </span>
        <.link
          navigate={~p"/changelog"}
          class="text-xs hover:underline"
          style="color: var(--ink-3);"
        >
          {gettext("Now in release →")}
        </.link>
      </div>

      <h1
        class="m-0 font-semibold"
        style="font-size: clamp(36px, 6vw, 72px); letter-spacing: -0.04em; line-height: 0.98; max-width: 1100px; color: var(--ink); text-wrap: pretty;"
      >
        <span style="color: var(--ink-3);">
          {gettext("Tasks are conversations.")}
        </span>
        <br />
        {gettext("Stride can speak both ways.")}
      </h1>

      <p
        class="mt-6"
        style="max-width: 620px; font-size: 17.5px; line-height: 1.5; color: var(--ink-2); text-wrap: pretty;"
      >
        {gettext(
          "Stride is an AI-native work management system. Humans plan, review, and approve. Agents claim, build, and ship. Same board. One workflow. No glue code."
        )}
      </p>

      <div class="flex flex-col md:flex-row md:flex-wrap items-stretch md:items-center gap-3 md:gap-3.5 mt-8">
        <%= if @current_scope do %>
          <.link
            href={~p"/boards"}
            class="inline-flex items-center gap-1.5 px-4 py-2.5 rounded-md text-sm font-medium hover:opacity-90 transition-opacity"
            style="background: var(--ink); color: var(--surface);"
          >
            {gettext("Go to my boards")}
            <.icon name="hero-arrow-right" class="w-3 h-3" />
          </.link>
        <% else %>
          <.link
            href={~p"/users/register"}
            class="inline-flex items-center gap-1.5 px-4 py-2.5 rounded-md text-sm font-medium hover:opacity-90 transition-opacity"
            style="background: var(--ink); color: var(--surface);"
          >
            {gettext("Start now")}
            <.icon name="hero-arrow-right" class="w-3 h-3" />
          </.link>
        <% end %>

        <%= if @has_boards do %>
          <.link
            navigate={~p"/resources/inviting-team-members"}
            class="inline-flex items-center gap-1.5 px-4 py-2.5 rounded-md text-sm font-medium hover:opacity-90 transition-opacity"
            style="background: transparent; color: var(--ink); border: 1px solid var(--line-strong);"
          >
            <.icon name="hero-user-plus" class="w-3 h-3" />
            {gettext("Learn about adding team members")}
          </.link>
        <% else %>
          <.link
            navigate={~p"/resources/creating-your-first-board"}
            class="inline-flex items-center gap-1.5 px-4 py-2.5 rounded-md text-sm font-medium hover:opacity-90 transition-opacity"
            style="background: transparent; color: var(--ink); border: 1px solid var(--line-strong);"
          >
            <.icon name="hero-rectangle-stack" class="w-3 h-3" />
            {gettext("Learn about creating a board")}
          </.link>
        <% end %>

        <span
          class="inline-flex items-center gap-1.5 md:ml-1.5 text-xs"
          style="color: var(--ink-3);"
        >
          <.icon name="hero-check" class="w-2.5 h-2.5" />
          {gettext("Free for you and your teams · self-hosting options available")}
        </span>
      </div>

      <div
        class="mt-10 md:mt-16 overflow-x-auto md:overflow-x-visible pb-3 md:pb-0 [mask-image:linear-gradient(to_right,black_calc(100%-32px),transparent_100%)] md:[mask-image:none]"
        style="max-width: 1200px;"
      >
        <div class="min-w-[640px] md:min-w-0">
          <.marketing_mini_board />
        </div>
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
    <section
      class="px-5 py-10 md:px-16 md:py-16 md:pb-14"
      style="border-bottom: 1px solid var(--line);"
    >
      <div class="grid grid-cols-1 gap-8 md:gap-20 items-baseline md:[grid-template-columns:1.2fr_1fr]">
        <div>
          <span class="ucase">{gettext("A new contract")}</span>
          <h2
            class="font-semibold"
            style="margin: 12px 0 0; font-size: clamp(28px, 5vw, 40px); letter-spacing: -0.03em; line-height: 1.1; text-wrap: pretty;"
          >
            {gettext("AI agents are first-class teammates,")}
            <br />
            <span style="color: var(--stride-orange-ink);">
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
              "Humans get a fast, calm board they can use to plan and review. Agents get an API rich enough to complete their work without asking. The same board feels native to both."
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
    <section
      class="px-5 pt-10 pb-6 md:px-16 md:pt-16 md:pb-8"
      style="border-bottom: 1px solid var(--line);"
    >
      <div class="flex flex-col gap-3 mb-7 md:mb-9">
        <span class="ucase">{gettext("How it works")}</span>
        <h2
          class="font-semibold"
          style="margin: 0; font-size: clamp(28px, 5vw, 40px); letter-spacing: -0.03em; line-height: 1.1; text-wrap: pretty;"
        >
          {gettext("One loop.")}
          <span style="color: var(--stride-orange-ink);">
            {gettext("Two roles.")}
          </span>
        </h2>
      </div>

      <div
        class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 overflow-hidden"
        style="gap: 0; border: 1px solid var(--line); border-radius: 12px;"
      >
        <div
          :for={{step, index} <- Enum.with_index(@steps)}
          class={[
            "flex flex-col gap-3 p-6 md:p-[24px_22px_26px]",
            how_it_works_card_borders(index)
          ]}
          style="background: var(--surface); border-color: var(--line);"
        >
          <div class="flex items-center gap-2.5">
            <span style="font-family: var(--font-mono); font-size: 11px; color: var(--ink-3); font-weight: 500;">
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

  @doc """
  Renders the 6-card audience-tagged feature grid.

  Three audiences: agents (`--stride-orange-ink` tag), humans (`--stride-violet-ink`
  tag), teams (`--ink-3` tag). Mirrors lines ~285-324 of `landing.jsx`.

  ## Examples

      <.marketing_feature_grid />
  """
  def marketing_feature_grid(assigns) do
    assigns = assign(assigns, :features, feature_grid_cards())

    ~H"""
    <section class="px-5 pt-6 pb-10 md:px-16 md:pt-8 md:pb-16">
      <span class="ucase block mb-7 md:mb-9">{gettext("A few features")}</span>
      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3.5">
        <div
          :for={feature <- @features}
          class="flex flex-col gap-2"
          style="background: var(--surface); border: 1px solid var(--line); border-radius: 10px; padding: 18px 18px 16px; min-height: 154px;"
        >
          <span class="ucase" style={"font-size: 9.5px; color: #{tag_color(feature.audience)};"}>
            {feature.tag}
          </span>
          <h3
            class="font-semibold"
            style="margin: 0; font-size: 15.5px; letter-spacing: -0.015em;"
          >
            {feature.title}
          </h3>
          <p style="margin: 0; font-size: 13px; line-height: 1.5; color: var(--ink-2); text-wrap: pretty;">
            {feature.body}
          </p>
        </div>
      </div>
    </section>
    """
  end

  defp tag_color(:agents), do: "var(--stride-orange-ink)"
  defp tag_color(:humans), do: "var(--stride-violet-ink)"
  defp tag_color(:teams), do: "var(--ink-3)"

  defp feature_grid_cards do
    [
      %{
        audience: :agents,
        tag: gettext("For agents"),
        title: gettext("Capability matching"),
        body:
          gettext(
            "Agents declare what they can do. They only see — and can only claim — work that matches."
          )
      },
      %{
        audience: :agents,
        tag: gettext("For agents"),
        title: gettext("Client-side hooks"),
        body:
          gettext(
            "before_doing, after_doing, before_review, after_review. They run on the agent's machine, not yours."
          )
      },
      %{
        audience: :agents,
        tag: gettext("For agents"),
        title: gettext("Conflict prevention"),
        body:
          gettext(
            "Tasks declare key_files. Two agents can't touch the same code at the same time."
          )
      },
      %{
        audience: :humans,
        tag: gettext("For humans"),
        title: gettext("Review at the speed of approval"),
        body:
          gettext(
            "Diff, tests, acceptance, hook telemetry — one pane. Approve with one keystroke."
          )
      },
      %{
        audience: :humans,
        tag: gettext("For humans"),
        title: gettext("Goals → tasks → outcomes"),
        body:
          gettext(
            "Plan at the level you think at. Stride decomposes into the work agents can actually claim with the details they need to be accurate."
          )
      },
      %{
        audience: :teams,
        tag: gettext("For teams"),
        title: gettext("Real metrics that include AI"),
        body:
          gettext(
            "Cycle time split by agent vs human. Throughput. Where your humans are the bottleneck."
          )
      }
    ]
  end

  defp how_it_works_card_borders(0), do: "border-b md:border-r lg:border-b-0"
  defp how_it_works_card_borders(1), do: "border-b lg:border-b-0 lg:border-r"
  defp how_it_works_card_borders(2), do: "border-b md:border-b-0 md:border-r"
  defp how_it_works_card_borders(_), do: ""

  defp how_it_works_steps do
    [
      %{
        number: "01",
        title: gettext("You write or review the task"),
        body:
          gettext(
            "Why, what, where, acceptance criteria, testing strategy, security concerns, etc.. The schema is the conversation."
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
            "running tests, creating PRs, whatever you put in .stride.md. You hold the keys; agents hold the loop."
          ),
        icon: "hero-bolt",
        color: "var(--stride-orange)"
      },
      %{
        number: "04",
        title: gettext("You approve or send back"),
        body:
          gettext(
            "Diff, tests, acceptance — all in one pane. ⌘Agent responds to your review. Done."
          ),
        icon: "hero-check",
        color: "var(--st-done)"
      }
    ]
  end
end
