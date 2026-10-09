defmodule KanbanWeb.SideNav do
  @moduledoc """
  The authenticated app's side navigation, rendered by `KanbanWeb.Layouts.app/1`.

  Extracted from `KanbanWeb.Layouts` so the layouts module stays below the
  500-line guideline. `primary_nav_items/1` is the single source of truth for
  the workspace destinations (labels, icons and routes) the nav renders.
  """
  use KanbanWeb, :html

  alias KanbanWeb.Avatar

  @doc """
  The authenticated-app SideNav. Renders the Stride logo header, primary nav
  items (Boards/My Work/Agents/Review queue/Metrics) styled to the design source, plus
  a small secondary section for Resources/Settings, and a footer with the
  current user's identity + log-out.
  """
  attr :current_scope, :map, required: true
  attr :active, :atom, default: nil

  attr :board, :map,
    default: nil,
    doc: "Reserved for future board-aware nav state. Currently unused by the nav itself."

  def side_nav(assigns) do
    assigns = assign(assigns, :primary_items, primary_nav_items(assigns.board))
    assigns = assign(assigns, :secondary_items, secondary_nav_items())

    ~H"""
    <aside
      id="app-sidebar"
      aria-label={gettext("Primary navigation")}
      class="w-[200px] md:w-[160px] flex-shrink-0 fixed inset-y-0 left-0 z-50 -translate-x-full transition-transform md:static md:translate-x-0 md:z-auto h-screen"
      style={[
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

      <%!-- Two navs in one sidebar: each needs its own name, or assistive tech
            lists two identical "navigation" landmarks. --%>
      <nav
        aria-label={gettext("Workspace")}
        style="padding: 6px; display: flex; flex-direction: column; gap: 1px;"
      >
        <.side_nav_item :for={item <- @primary_items} item={item} active={@active} />
      </nav>

      <div style="margin-top: 8px; padding: 0 10px 6px;">
        <hr style="border: 0; border-top: 1px solid var(--line);" />
      </div>

      <nav
        aria-label={gettext("Resources and information")}
        style="padding: 0 6px 6px; display: flex; flex-direction: column; gap: 1px;"
      >
        <.side_nav_item :for={item <- @secondary_items} item={item} active={@active} />
      </nav>

      <span style="flex: 1;"></span>

      <div style={[
        "padding: 10px; border-top: 1px solid var(--line);",
        "display: flex; flex-direction: column; gap: 8px;"
      ]}>
        <%= if @current_scope && @current_scope.user do %>
          <div style="display: flex; align-items: center; gap: 8px; min-width: 0;">
            <span style={[
              "width: 24px; height: 24px; border-radius: 50%; flex-shrink: 0;",
              "background: var(--stride-orange-soft); color: var(--stride-orange-ink);",
              "display: inline-flex; align-items: center; justify-content: center;",
              "font-size: 10px; font-weight: 600;"
            ]}>
              {user_initials(@current_scope.user)}
            </span>
            <span style="font-size: 12px; font-weight: 500; color: var(--ink); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; flex: 1;">
              {user_display_name(@current_scope.user)}
            </span>
          </div>
          <div style="display: flex; align-items: center; justify-content: space-between;">
            <.link
              navigate={~p"/users/settings"}
              aria-label={gettext("Settings")}
              title={gettext("Settings")}
              style={[
                "display: inline-flex; align-items: center; justify-content: center;",
                "width: 24px; height: 24px; border-radius: 5px;",
                "color: #{if @active == :settings, do: "var(--stride-orange)", else: "var(--ink-3)"};",
                "background: #{if @active == :settings, do: "var(--surface)", else: "transparent"};",
                "box-shadow: #{if @active == :settings, do: "inset 0 0 0 1px var(--line)", else: "none"};",
                "text-decoration: none;"
              ]}
            >
              <.icon name="hero-cog-6-tooth" class="w-4 h-4" />
            </.link>
            <.link
              href={~p"/users/log-out"}
              method="delete"
              style={[
                "display: inline-flex; align-items: center; gap: 4px;",
                "padding-right: 6px;",
                "font-size: 11.5px; font-weight: 500;",
                "color: var(--ink-2); text-decoration: underline;",
                "text-underline-offset: 2px; cursor: pointer;"
              ]}
            >
              <.icon name="hero-arrow-right-on-rectangle" class="w-3 h-3" />
              {gettext("Log out")}
            </.link>
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

  @doc """
  The canonical primary workspace navigation items, in sidebar order:
  Boards, My Work, Agents, Review queue, Metrics.

  Each entry is a `%{id:, label:, icon:, path:, badge:}` map. This is the
  single source of truth for those labels, icons and routes — `side_nav/1`
  renders all five. Anything that needs one of these destinations must
  read it from here rather than re-declaring the literal, so a route or
  label change lands everywhere at once.

  Note `:metrics` is the WORKSPACE metrics route (`/metrics`,
  `MetricsLive.Workspace`), not the per-board dashboard at
  `/boards/:id/metrics`.

  The board argument is reserved for future board-aware nav state and is
  currently ignored.
  """
  def primary_nav_items(_board \\ nil) do
    [
      %{
        id: :boards,
        label: gettext("Boards"),
        icon: "hero-squares-2x2",
        path: "/boards",
        badge: nil
      },
      %{
        id: :my_work,
        label: gettext("My Work"),
        icon: "hero-user-circle",
        path: "/my-work",
        badge: nil
      },
      %{
        id: :agents,
        label: gettext("Agents"),
        icon: "hero-cpu-chip",
        path: "/agents",
        badge: nil
      },
      %{
        id: :review,
        label: gettext("Review queue"),
        icon: "hero-check-circle",
        path: "/review",
        badge: nil
      },
      %{
        id: :metrics,
        label: gettext("Metrics"),
        icon: "hero-chart-bar",
        path: "/metrics",
        badge: nil
      }
    ]
  end

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
        id: :about,
        label: gettext("About"),
        icon: "hero-information-circle",
        path: "/about",
        badge: nil
      }
    ]
  end

  defp user_initials(user), do: user |> user_display_name() |> Avatar.initials(~r/[\s@.]/)

  defp user_display_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp user_display_name(%{email: email}) when is_binary(email), do: email
  defp user_display_name(_), do: "?"
end
