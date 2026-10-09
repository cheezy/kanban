defmodule KanbanWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use KanbanWeb, :html

  import KanbanWeb.MarketingComponents
  import KanbanWeb.MarketingClosing

  alias KanbanWeb.NotificationBell
  alias KanbanWeb.SideNav
  alias KanbanWeb.TwoFactorReminder

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :active, :atom,
    default: nil,
    doc:
      "Highlights the matching SideNav item when rendered inside the app shell. " <>
        "Accepted values: :boards, :my_work, :agents, :review, :metrics, :resources, :about, :settings."

  attr :page_title, :string,
    default: nil,
    doc: "Overrides the WinTop breadcrumb title when set."

  attr :board, :any,
    default: nil,
    doc: "The current board struct when the LiveView is in a single-board context."

  slot :breadcrumbs, doc: "WinTop breadcrumbs content (overrides page_title when present)."
  slot :actions, doc: "WinTop right-side actions slot."
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div
      id="app-shell"
      phx-hook="Sidebar"
      class="stride-screen flex h-screen w-full overflow-hidden"
    >
      <%= if @current_scope do %>
        <div
          data-sidebar-backdrop
          aria-hidden="true"
          class={
            [
              # dark-mode-ignore: intentional darkening backdrop for the mobile drawer
              "hidden md:hidden fixed inset-0 bg-black/40 z-40"
            ]
          }
        />
        <SideNav.side_nav
          current_scope={@current_scope}
          active={@active}
          board={@board}
        />
      <% end %>

      <div class="flex flex-col flex-1 min-w-0">
        <.win_top
          breadcrumbs={@breadcrumbs}
          actions={@actions}
          page_title={@page_title}
          show_sidebar_toggle={@current_scope != nil}
          current_scope={@current_scope}
        />
        <%!-- D48: in dark the canvas must sit at --bg (base-200, 16%), not the
              raised-card tone (base-100, 20%), so cards/columns read above it.
              dark: variant keeps light mode (base-100, 98%) identical. --%>
        <%!-- tabindex="-1" lets scripts move focus here (as when the two-factor
              reminder is dismissed) without adding <main> to the tab order. --%>
        <main
          tabindex="-1"
          class="flex-1 min-h-0 overflow-auto bg-base-100 dark:bg-base-200 focus:outline-none"
        >
          <TwoFactorReminder.card current_scope={@current_scope} />
          {render_slot(@inner_block)}
        </main>
      </div>

      <%!-- The flash card reads its --flash-*-bg surface tokens from the
            .stride-screen scope (light: .stride-screen; dark: [data-theme=dark]
            .stride-screen). It MUST render inside this container — as a sibling
            it fell outside that scope, so var(--flash-info-bg) resolved to
            nothing and the card rendered with a transparent background (D104
            never took effect). The toast is position: fixed, so nesting it here
            does not change where it appears on screen. --%>
      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  The WinTop bar — the page header that sits above the main content area
  inside the authenticated app shell. Shows traffic-light decoration dots
  on the left, breadcrumbs (or a `:page_title`) in the middle, and an
  optional `:actions` slot on the right, followed by the notification bell
  when a user is signed in.
  """
  attr :breadcrumbs, :any, default: []
  attr :actions, :any, default: []
  attr :page_title, :string, default: nil
  attr :show_sidebar_toggle, :boolean, default: false
  attr :current_scope, :map, default: nil, doc: "shows the notification bell when it has a user"

  def win_top(assigns) do
    ~H"""
    <%!-- A <header> outside <main> is the page's banner landmark, so the
          breadcrumbs, page actions and notification bell are reachable by
          landmark navigation like the sidebar and main content. --%>
    <header
      class="stride-screen flex-wrap lg:flex-nowrap"
      style={[
        "min-height: 36px; display: flex; align-items: center; flex-shrink: 0;",
        "border-bottom: 1px solid var(--line); background: var(--surface);",
        "padding: 0 10px 0 12px; column-gap: 10px; row-gap: 0;"
      ]}
    >
      <%= if @show_sidebar_toggle do %>
        <button
          type="button"
          data-sidebar-toggle
          class="md:hidden inline-flex shrink-0 items-center justify-center w-11 h-11 rounded-md hover:opacity-70 transition-opacity focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
          style="color: var(--ink-2); margin-left: -6px;"
          aria-label={gettext("Toggle sidebar")}
          aria-controls="app-sidebar"
          aria-expanded="false"
        >
          <.icon name="hero-bars-3" class="w-5 h-5" />
        </button>
      <% end %>
      <div class="hidden md:flex" style="gap: 6px;" aria-hidden="true">
        <%!-- dark-mode-ignore: brand status dot (red), fixed contrast on both themes --%>
        <span style="width: 10px; height: 10px; border-radius: 50%; background: oklch(75% 0.13 25); display: inline-block;"></span>
        <%!-- dark-mode-ignore: brand status dot (yellow), fixed contrast on both themes --%>
        <span style="width: 10px; height: 10px; border-radius: 50%; background: oklch(80% 0.13 80); display: inline-block;"></span>
        <%!-- dark-mode-ignore: brand status dot (green), fixed contrast on both themes --%>
        <span style="width: 10px; height: 10px; border-radius: 50%; background: oklch(70% 0.14 145); display: inline-block;"></span>
      </div>
      <div style="width: 1px; height: 14px; background: var(--line-2); margin-left: 4px;"></div>

      <div style="flex: 1 1 0; min-width: 0; overflow: hidden; white-space: nowrap; display: flex; align-items: center; gap: 6px; font-size: 12px; color: var(--ink-3);">
        <%= if @breadcrumbs not in [nil, []] do %>
          {render_slot(@breadcrumbs)}
        <% else %>
          <span style="color: var(--ink); font-weight: 500;">{@page_title || gettext("Stride")}</span>
        <% end %>
      </div>

      <%!-- Below lg the actions take their own full-width row and wrap; no overflow clips dropdowns. --%>
      <div
        :if={@actions not in [nil, []]}
        data-win-top-actions
        class="[&>*]:shrink-0 max-lg:order-last max-lg:basis-full max-lg:flex-wrap max-lg:pb-2"
        style="display: flex; align-items: center; gap: 8px; color: var(--ink-3); font-size: 11.5px;"
      >
        {render_slot(@actions)}
      </div>
      <NotificationBell.bell current_scope={@current_scope} />
    </header>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <%!-- The indicator tracks the user's CHOICE (data-theme-choice), not the
            resolved data-theme: in "system" mode the bootstrap sets a concrete
            data-theme (light/dark) but keeps data-theme-choice="system", so the
            pill stays on the system position. --%>
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme-choice=light]_&]:left-1/3 [[data-theme-choice=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
