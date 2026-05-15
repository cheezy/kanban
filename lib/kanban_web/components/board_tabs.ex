defmodule KanbanWeb.BoardTabs do
  @moduledoc """
  Horizontal tab row that sits directly under the board name header on
  every board-scoped screen. Mirrors the `BoardTabs` JSX block at lines
  271-315 of `design_handoff_stride/design_source/primitives.jsx`.

  The active tab gets a `var(--stride-orange)` underline + colored icon
  and bold text; inactive tabs use `var(--ink-3)` text and an
  `var(--ink-4)` icon. Tabs that don't have a real route yet (List,
  Goals, Members) point back to the board show page like the
  placeholder SideNav items. Owner-only tabs (Tokens, Settings) are
  hidden unless the `:owner?` attr is true.
  """
  use KanbanWeb, :html

  @doc """
  Renders the tab row.

  ## Attrs

    * `board` — board struct or map with `:id`. Required.
    * `active` — the currently active tab atom (one of
      `:board | :goals | :archive | :members | :tokens | :settings`).
      An unknown atom renders no active underline. Default `:board`.
    * `owner?` — when true, owner-only tabs (Settings) plus tabs
      gated by `can_modify?` are visible. Default false.
    * `can_modify?` — when true (or when `owner?` is true), the
      Tokens tab is visible. Default false.
  """
  attr :board, :map, required: true
  attr :active, :atom, default: :board
  attr :owner?, :boolean, default: false
  attr :can_modify?, :boolean, default: false

  def board_tabs(assigns) do
    assigns =
      assign(
        assigns,
        :tabs,
        visible_tabs(assigns.board, assigns.owner?, assigns.can_modify? || assigns.owner?)
      )

    ~H"""
    <nav
      class="board-tabs-bar"
      aria-label={gettext("Board sections")}
      style={[
        "display: flex; align-items: stretch; gap: 0;",
        "padding: 0 22px;",
        "border-bottom: 1px solid var(--line);",
        "background: var(--surface); flex-shrink: 0;",
        "overflow-x: auto;"
      ]}
    >
      <.tab :for={tab <- @tabs} tab={tab} active={@active == tab.id} />
    </nav>
    """
  end

  attr :tab, :map, required: true
  attr :active, :boolean, required: true

  defp tab(assigns) do
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
      navigate={@tab.path}
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
        <.icon name={@tab.icon} class="w-3 h-3" />
      </span>
      {@tab.label}
    </.link>
    """
  end

  # --- Helpers -------------------------------------------------------------

  defp visible_tabs(board, owner?, tokens_visible?) do
    board
    |> all_tabs()
    |> Enum.reject(fn tab ->
      case tab.id do
        :settings -> not owner?
        :tokens -> not tokens_visible?
        _ -> false
      end
    end)
  end

  defp all_tabs(board) do
    bid = Map.fetch!(board, :id)

    [
      %{id: :board, label: gettext("Board"), icon: "hero-view-columns", path: "/boards/#{bid}"},
      %{id: :goals, label: gettext("Goals"), icon: "hero-flag", path: "/boards/#{bid}"},
      %{
        id: :archive,
        label: gettext("Archive"),
        icon: "hero-archive-box",
        path: "/boards/#{bid}/archive"
      },
      %{id: :members, label: gettext("Members"), icon: "hero-user", path: "/boards/#{bid}"},
      %{
        id: :tokens,
        label: gettext("Tokens"),
        icon: "hero-key",
        path: "/boards/#{bid}/api_tokens"
      },
      %{
        id: :settings,
        label: gettext("Settings"),
        icon: "hero-cog-6-tooth",
        path: "/boards/#{bid}"
      }
    ]
  end
end
