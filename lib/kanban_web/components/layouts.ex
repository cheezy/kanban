defmodule KanbanWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use KanbanWeb, :html

  import KanbanWeb.NavComponents
  import KanbanWeb.MarketingComponents
  import KanbanWeb.MarketingClosing

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
        "Accepted values: :boards, :goals, :agents, :review, :metrics, :resources, :settings."

  attr :page_title, :string,
    default: nil,
    doc: "Overrides the WinTop breadcrumb title when set."

  attr :board, :any,
    default: nil,
    doc:
      "The current board struct when the LiveView is in a single-board context. " <>
        "When set with a non-nil id, the SideNav surfaces Goals / Agents / Review / Metrics " <>
        "links scoped to that board."

  slot :breadcrumbs, doc: "WinTop breadcrumbs content (overrides page_title when present)."
  slot :actions, doc: "WinTop right-side actions slot."
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="stride-screen flex h-screen w-full overflow-hidden">
      <%= if @current_scope do %>
        <.side_nav
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
        />
        <main class="flex-1 min-h-0 overflow-auto bg-base-100">
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  The authenticated-app SideNav. Renders the Stride logo header, primary nav
  items (Boards/Goals/Agents/Review/Metrics) styled to the design source, plus
  a small secondary section for Resources/Settings, and a footer with the
  current user's identity + log-out.
  """
  attr :current_scope, :map, required: true
  attr :active, :atom, default: nil

  attr :board, :map,
    default: nil,
    doc:
      "When set, the SideNav surfaces board-scoped items (Goals / Agents / " <>
        "Review queue / Metrics) pointing into that board. When nil, only " <>
        "the workspace-level Boards item is shown."

  def side_nav(assigns) do
    assigns = assign(assigns, :primary_items, primary_nav_items(assigns.board))
    assigns = assign(assigns, :secondary_items, secondary_nav_items())

    ~H"""
    <aside
      aria-label={gettext("Primary navigation")}
      style={[
        "width: 160px; height: 100vh; flex-shrink: 0;",
        "background: var(--surface-2); border-right: 1px solid var(--line);",
        "display: flex; flex-direction: column;"
      ]}
    >
      <.link
        href={~p"/"}
        aria-label={gettext("Stride home")}
        style={[
          "padding: 14px 14px 12px; display: flex; align-items: center; gap: 8px;",
          "text-decoration: none; color: inherit;"
        ]}
      >
        <img
          src={~p"/images/logos/abstract-s-motion.svg"}
          alt=""
          aria-hidden="true"
          style="width: 22px; height: 22px;"
        />
        <span style="font-weight: 600; font-size: 13px; letter-spacing: -0.01em; color: var(--ink);">
          {gettext("Stride")}
        </span>
      </.link>

      <nav style="padding: 6px; display: flex; flex-direction: column; gap: 1px;">
        <.side_nav_item :for={item <- @primary_items} item={item} active={@active} />
      </nav>

      <div style="margin-top: 8px; padding: 0 10px 6px;">
        <hr style="border: 0; border-top: 1px solid var(--line);" />
      </div>

      <nav style="padding: 0 6px 6px; display: flex; flex-direction: column; gap: 1px;">
        <.side_nav_item :for={item <- @secondary_items} item={item} active={@active} />
      </nav>

      <span style="flex: 1;"></span>

      <div style={[
        "padding: 10px; border-top: 1px solid var(--line);",
        "display: flex; align-items: center; gap: 8px;"
      ]}>
        <%= if @current_scope && @current_scope.user do %>
          <span style={[
            "width: 24px; height: 24px; border-radius: 50%;",
            "background: var(--stride-orange-soft); color: var(--stride-orange-ink);",
            "display: inline-flex; align-items: center; justify-content: center;",
            "font-size: 10px; font-weight: 600;"
          ]}>
            {user_initials(@current_scope.user)}
          </span>
          <div style="display: flex; flex-direction: column; min-width: 0; flex: 1;">
            <span style="font-size: 12px; font-weight: 500; color: var(--ink); overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
              {user_display_name(@current_scope.user)}
            </span>
            <a
              href={~p"/users/log-out"}
              data-method="delete"
              style={[
                "display: inline-flex; align-items: center; gap: 4px;",
                "font-size: 11.5px; font-weight: 500;",
                "color: var(--ink-2); text-decoration: underline;",
                "text-underline-offset: 2px; cursor: pointer;"
              ]}
            >
              <.icon name="hero-arrow-right-on-rectangle" class="w-3 h-3" />
              {gettext("Log out")}
            </a>
          </div>
        <% end %>
      </div>
    </aside>
    """
  end

  defp side_nav_item(assigns) do
    is_active = assigns.active == assigns.item.id

    assigns =
      assigns
      |> assign(:is_active, is_active)
      |> assign(:bg, if(is_active, do: "var(--surface)", else: "transparent"))
      |> assign(:fg, if(is_active, do: "var(--ink)", else: "var(--ink-2)"))
      |> assign(:icon_fg, if(is_active, do: "var(--stride-orange)", else: "var(--ink-4)"))
      |> assign(:weight, if(is_active, do: 600, else: 500))
      |> assign(:shadow, if(is_active, do: "inset 0 0 0 1px var(--line)", else: "none"))

    ~H"""
    <.link
      navigate={@item.path}
      style={[
        "display: flex; align-items: center; gap: 8px;",
        "padding: 5px 8px; border-radius: 5px;",
        "font-size: 12.5px; font-weight: #{@weight};",
        "color: #{@fg}; background: #{@bg}; box-shadow: #{@shadow};",
        "text-decoration: none;"
      ]}
    >
      <span style={"color: #{@icon_fg}; display: inline-flex;"}>
        <.icon name={@item.icon} class="w-3.5 h-3.5" />
      </span>
      {@item.label}
      <span
        :if={@item.badge}
        style={[
          "margin-left: auto; font-family: var(--font-mono);",
          "font-size: 10.5px; padding: 0 5px; border-radius: 3px;",
          "background: var(--surface-sunken); color: var(--ink-3); font-weight: 500;"
        ]}
      >
        {@item.badge}
      </span>
    </.link>
    """
  end

  defp primary_nav_items(board) do
    workspace = [
      %{
        id: :boards,
        label: gettext("Boards"),
        icon: "hero-squares-2x2",
        path: "/boards",
        badge: nil
      }
    ]

    workspace ++ board_scoped_items(board)
  end

  # Board-scoped items only appear when the current page has a `:board`
  # assign — i.e., the user is inside a specific board. Goals / Agents /
  # Review queue currently point to the board show page until those
  # screens land; Metrics has a real dashboard route.
  defp board_scoped_items(%{id: id}) when is_integer(id) or is_binary(id) do
    [
      %{
        id: :goals,
        label: gettext("Goals"),
        icon: "hero-flag",
        path: "/boards/#{id}",
        badge: nil
      },
      %{
        id: :agents,
        label: gettext("Agents"),
        icon: "hero-cpu-chip",
        path: "/boards/#{id}",
        badge: nil
      },
      %{
        id: :review,
        label: gettext("Review queue"),
        icon: "hero-check-circle",
        path: "/boards/#{id}",
        badge: nil
      },
      %{
        id: :metrics,
        label: gettext("Metrics"),
        icon: "hero-chart-bar",
        path: "/boards/#{id}/metrics",
        badge: nil
      }
    ]
  end

  defp board_scoped_items(_), do: []

  defp secondary_nav_items do
    [
      %{
        id: :resources,
        label: gettext("Resources"),
        icon: "hero-book-open",
        path: "/resources",
        badge: nil
      },
      %{
        id: :settings,
        label: gettext("Settings"),
        icon: "hero-cog-6-tooth",
        path: "/users/settings",
        badge: nil
      }
    ]
  end

  defp user_initials(user) do
    name = user_display_name(user)

    name
    |> String.split(~r/[\s@.]/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", &String.first/1)
    |> String.upcase()
  end

  defp user_display_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp user_display_name(%{email: email}) when is_binary(email), do: email
  defp user_display_name(_), do: "?"

  @doc """
  The WinTop bar — the page header that sits above the main content area
  inside the authenticated app shell. Shows traffic-light decoration dots
  on the left, breadcrumbs (or a `:page_title`) in the middle, and an
  optional `:actions` slot on the right.
  """
  attr :breadcrumbs, :any, default: []
  attr :actions, :any, default: []
  attr :page_title, :string, default: nil

  def win_top(assigns) do
    ~H"""
    <div
      class="stride-screen"
      style={[
        "height: 36px; display: flex; align-items: center; flex-shrink: 0;",
        "border-bottom: 1px solid var(--line); background: var(--surface);",
        "padding: 0 10px 0 12px; gap: 10px;"
      ]}
    >
      <div style="display: flex; gap: 6px;" aria-hidden="true">
        <span style="width: 10px; height: 10px; border-radius: 50%; background: oklch(75% 0.13 25); display: inline-block;">
        </span>
        <span style="width: 10px; height: 10px; border-radius: 50%; background: oklch(80% 0.13 80); display: inline-block;">
        </span>
        <span style="width: 10px; height: 10px; border-radius: 50%; background: oklch(70% 0.14 145); display: inline-block;">
        </span>
      </div>
      <div style="width: 1px; height: 14px; background: var(--line-2); margin-left: 4px;"></div>

      <div style="display: flex; align-items: center; gap: 6px; font-size: 12px; color: var(--ink-3);">
        <%= if @breadcrumbs not in [nil, []] do %>
          {render_slot(@breadcrumbs)}
        <% else %>
          <span style="color: var(--ink); font-weight: 500;">{@page_title || gettext("Stride")}</span>
        <% end %>
      </div>

      <span style="flex: 1;"></span>

      <div style="display: flex; align-items: center; gap: 8px; color: var(--ink-3); font-size: 11.5px;">
        <%= if @actions not in [nil, []] do %>
          {render_slot(@actions)}
        <% end %>
      </div>
    </div>
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
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

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
