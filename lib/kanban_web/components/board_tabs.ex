defmodule KanbanWeb.BoardTabs do
  @moduledoc """
  Horizontal tab row that sits directly under the board name header on
  every board-scoped screen. Mirrors the `BoardTabs` block of the design
  handoff's `primitives.jsx`, which is kept outside version control.

  The active tab gets a `var(--stride-orange)` underline + colored icon
  and bold text; inactive tabs use `var(--ink-3)` text and an
  `var(--ink-4)` icon. Tabs that don't have a real route yet (List,
  Goals, Members) point back to the board show page like the
  placeholder SideNav items. The Settings tab is shown to every board
  member (`:member?`, `:can_modify?` or `:owner?`), because members see
  the board's labels there and modify users manage them (W2233); the
  board-details form inside it stays owner-only. The Tokens tab needs
  `:can_modify?` or `:owner?`. The Integrations tab (webhook and Slack
  endpoints, W2228) is owner-only, on every board.
  """
  use KanbanWeb, :html

  @doc """
  Renders the tab row.

  ## Attrs

    * `board` — board struct or map with `:id`. Required.
    * `active` — the currently active tab atom (one of
      `:board | :archive | :metrics | :tokens | :members | :settings |
      :integrations`).
      An unknown atom renders no active underline. Default `:board`.
    * `owner?` — when true, every tab gated by `can_modify?` is
      visible too, and so is the owner-only Integrations tab. Default
      false.
    * `can_modify?` — when true (or when `owner?` is true), the
      Settings tab and (on an AI-optimized board) the Tokens tab are
      visible. Default false.
    * `member?` — when true, the Settings tab is visible to a read-only
      member too. Default false.
  """
  attr :board, :map, required: true
  attr :active, :atom, default: :board
  attr :owner?, :boolean, default: false
  attr :can_modify?, :boolean, default: false
  attr :member?, :boolean, default: false

  def board_tabs(assigns) do
    flags = %{
      owner?: assigns.owner?,
      modify?: assigns.can_modify? || assigns.owner?,
      member?: assigns.member? || assigns.can_modify? || assigns.owner?,
      ai_optimized?: Map.get(assigns.board, :ai_optimized_board, false)
    }

    assigns = assign(assigns, :tabs, visible_tabs(assigns.board, flags))

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

  defp visible_tabs(board, flags) do
    board
    |> all_tabs()
    |> Enum.reject(&hidden?(&1.id, flags))
  end

  defp hidden?(:settings, flags), do: not flags.member?
  defp hidden?(:tokens, flags), do: not (flags.modify? and flags.ai_optimized?)
  defp hidden?(:integrations, flags), do: not flags.owner?
  defp hidden?(_tab, _flags), do: false

  defp all_tabs(board) do
    bid = Map.fetch!(board, :id)

    [
      %{id: :board, label: gettext("Board"), icon: "hero-view-columns", path: "/boards/#{bid}"},
      %{
        id: :archive,
        label: gettext("Archive"),
        icon: "hero-archive-box",
        path: "/boards/#{bid}/archive"
      },
      %{
        id: :metrics,
        label: gettext("Metrics"),
        icon: "hero-chart-bar",
        path: "/boards/#{bid}/metrics"
      },
      %{
        id: :tokens,
        label: gettext("Tokens"),
        icon: "hero-key",
        path: "/boards/#{bid}/api_tokens"
      },
      %{
        id: :members,
        label: gettext("Members"),
        icon: "hero-user",
        path: "/boards/#{bid}/members"
      },
      %{
        id: :settings,
        label: gettext("Settings"),
        icon: "hero-cog-6-tooth",
        path: "/boards/#{bid}/settings"
      },
      %{
        id: :integrations,
        label: gettext("Integrations"),
        icon: "hero-puzzle-piece",
        path: "/boards/#{bid}/integrations"
      }
    ]
  end
end
