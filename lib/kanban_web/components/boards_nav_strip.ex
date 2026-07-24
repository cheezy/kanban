defmodule KanbanWeb.BoardsNavStrip do
  @moduledoc """
  Below-title link strip for the Boards index, pointing at the three
  workspace destinations: Agents, Review queue, and Metrics.

  The board-scoped screens have `KanbanWeb.BoardTabs` under the board-name
  header; this is the workspace-level counterpart, and it deliberately
  reproduces that component's tab presentation — same icon-plus-label link,
  same 12.5px type, same `var(--stride-orange)` active underline and colored
  icon, same `var(--ink-3)` / `var(--ink-4)` inactive tones.

  It does NOT reproduce BoardTabs' full-bleed bar chrome — `padding: 0 22px`,
  `background: var(--surface)`, and `flex-shrink: 0`. BoardTabs spans the
  whole viewport directly beneath the header band as a flex child of the app
  chrome, so it paints its own background, supplies its own gutters, and has
  to refuse to shrink. This strip sits inside the Boards index's `px-4 py-6`
  content well, where the gutters would double up, the surface fill would
  read as a stray panel, and `flex-shrink` is inert. The `border-bottom` is
  kept — it is what the active tab's `margin-bottom: -1px` underline sits
  on, so dropping it would break the tab metaphor.

  ## Contrast

  Measured against the canvas the Boards index actually paints
  (`bg-base-100` light / `dark:bg-base-200` dark), light is the tighter
  theme, not dark: active label `--ink` 17.8:1 / 16.8:1, inactive label
  `--ink-3` 5.2:1 / 8.7:1, inactive icon `--ink-4` 3.18:1 / 6.24:1, active
  icon and underline `--stride-orange` 3.13:1 / 7.35:1, border `--line`
  1.54:1 / 1.94:1. Every one clears its floor (4.5 text, 3.0 graphical,
  1.5 border), but the two icon tokens do so by under 6% in light.

  Two caveats for whoever touches this next. First, `mix dark_mode.contrast`
  does NOT guard these pairings — it measures `--stride-orange` and
  `--ink-4` against the Stride `--bg`/`--surface` tokens, never against the
  daisyUI canvas, and reports ~0.07 higher than what actually ships. A
  future re-tune could land a token at 3.00:1 in the tool and ~2.93:1 here
  with the suite still green. Second, the icons are 24/outline heroicons at
  `stroke-width: 1.5` rendered at 12px, i.e. a 0.75 CSS px stroke; on a 1x
  display antialiasing drops the delivered light-mode contrast well below
  the nominal figures above. Both are inherited from `BoardTabs`, which
  ships the same icons at the same size — worth fixing across both (larger
  icons, or the solid heroicon variant), not here alone.

  ## Where the labels and routes come from

  Nothing here is hardcoded. The entries are read from
  `KanbanWeb.Layouts.primary_nav_items/1`, the same list the left SideNav
  renders, so a label or route change lands in both places at once. That
  also means `:metrics` resolves to the workspace `/metrics`
  (`MetricsLive.Workspace`) and never to the per-board `/boards/:id/metrics`
  dashboard.
  """
  use KanbanWeb, :html

  alias KanbanWeb.Layouts

  # The subset of Layouts.primary_nav_items/1 this strip shows, in render
  # order. :boards is excluded — the strip lives ON the Boards index, so
  # linking to it would be a self-link.
  @item_ids [:agents, :review, :metrics]

  @doc """
  Renders the workspace nav strip.

  ## Attrs

    * `active` — the atom of the destination to mark as current, one of
      `:agents | :review | :metrics`. On the Boards index none of the three
      is active, so this defaults to `nil` and no underline is drawn. The
      attr exists so the strip can be reused on those three pages.
  """
  attr :active, :atom, default: nil

  def boards_nav_strip(assigns) do
    assigns = assign(assigns, :items, items())

    ~H"""
    <nav
      class="boards-nav-strip"
      aria-label={gettext("Workspace sections")}
      style={[
        "display: flex; align-items: stretch; gap: 0;",
        "border-bottom: 1px solid var(--line);",
        "overflow-x: auto;"
      ]}
    >
      <.item :for={item <- @items} item={item} active={@active == item.id} />
    </nav>
    """
  end

  attr :item, :map, required: true
  attr :active, :boolean, required: true

  defp item(assigns) do
    assigns =
      assigns
      |> assign(:text_color, if(assigns.active, do: "var(--ink)", else: "var(--ink-3)"))
      |> assign(:icon_color, if(assigns.active, do: "var(--stride-orange)", else: "var(--ink-4)"))
      |> assign(
        :underline,
        if(assigns.active, do: "2px solid var(--stride-orange)", else: "2px solid transparent")
      )
      |> assign(:weight, if(assigns.active, do: 600, else: 500))

    ~H"""
    <.link
      navigate={@item.path}
      aria-current={if @active, do: "page", else: nil}
      style={[
        "display: inline-flex; align-items: center; gap: 5px;",
        "padding: 8px 10px 9px;",
        "margin-bottom: -1px;",
        "font-size: 12.5px; font-weight: #{@weight};",
        "color: #{@text_color};",
        "border-bottom: #{@underline};",
        "text-decoration: none;"
      ]}
    >
      <span style={"color: #{@icon_color}; display: inline-flex;"}>
        <.icon name={@item.icon} class="w-3 h-3" />
      </span>
      {@item.label}
    </.link>
    """
  end

  # Selects @item_ids from the canonical list, in @item_ids order rather than
  # the sidebar's, so reordering the sidebar cannot silently reorder this
  # strip. Map.fetch!/2 raises if an id is ever dropped from the canonical
  # list — a loud failure beats quietly rendering two links.
  defp items do
    by_id = Map.new(Layouts.primary_nav_items(), &{&1.id, &1})

    Enum.map(@item_ids, &Map.fetch!(by_id, &1))
  end
end
