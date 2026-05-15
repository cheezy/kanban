defmodule KanbanWeb.BoardHeader do
  @moduledoc """
  Board-name header sub-band that sits between the BoardTabs row and
  the GoalsStrip on every board-scoped screen. Renders the board name
  + optional description + AI-optimized pill + a compact status-count
  summary ("X in flight · Y in review · Z shipped").

  Mirrors the subhead block at lines 362-380 of
  `design_handoff_stride/design_source/screens/board-kanban.jsx`.
  """
  use KanbanWeb, :html

  alias KanbanWeb.Avatar

  @doc """
  Renders the board header band.

  ## Attrs

    * `board` — board struct or map with `:name`, optional
      `:description`, optional `:ai_optimized_board`, and `:metrics`
      (the map shape returned by `Kanban.Boards.list_boards_with_metrics/2`
      or `get_board_metrics/3`). Required.
  """
  attr :board, :map, required: true

  def board_header(assigns) do
    metrics = Map.get(assigns.board, :metrics) || %{}

    assigns =
      assigns
      |> assign(:metrics, metrics)
      |> assign(:to_do, Map.get(metrics, :open, 0))
      |> assign(:in_flight, Map.get(metrics, :doing, 0))
      |> assign(:in_review, Map.get(metrics, :review, 0))
      |> assign(:shipped, Map.get(metrics, :done, 0))

    ~H"""
    <div
      class="board-header-bar"
      style={[
        "padding: 14px 22px 12px;",
        "display: flex; align-items: center; gap: 16px;",
        "flex-wrap: wrap;",
        "border-bottom: 1px solid var(--line);",
        "background: var(--surface);"
      ]}
    >
      <div style="display: flex; flex-direction: column; min-width: 0; flex: 1;">
        <div style="display: flex; align-items: center; gap: 8px;">
          <h1 style={[
            "margin: 0; font-size: 18px; font-weight: 600;",
            "letter-spacing: -0.015em; color: var(--ink);"
          ]}>
            {@board.name}
          </h1>
        </div>
        <span
          :if={present?(Map.get(@board, :description))}
          style="font-size: 11.5px; color: var(--ink-3); margin-top: 2px;"
        >
          {@board.description}
        </span>
      </div>

      <span style="flex: 1;"></span>

      <div style="display: flex; align-items: center; gap: 14px;">
        <.kv label={gettext("To Do")} value={@to_do} tone="var(--ink)" />
        <.kv label={gettext("Doing")} value={@in_flight} tone="var(--st-doing)" />
        <.kv label={gettext("in review")} value={@in_review} tone="var(--st-review)" />
        <.kv label={gettext("Done")} value={@shipped} tone="var(--st-done)" />
      </div>

      <.members_divider :if={members_present?(@board)} />
      <Avatar.avatar_stack
        :if={members_present?(@board)}
        members={Map.get(@board, :members, [])}
        max={6}
        size={20}
      />
    </div>
    """
  end

  defp members_divider(assigns) do
    ~H"""
    <span
      aria-hidden="true"
      style="width: 1px; height: 24px; background: var(--line);"
    >
    </span>
    """
  end

  defp members_present?(board) do
    case Map.get(board, :members) do
      list when is_list(list) and list != [] -> true
      _ -> false
    end
  end

  attr :board, :map, required: true
  attr :size, :integer, default: 28, doc: "Square size of the badge in pixels."

  @doc "Colored 3-letter identifier badge derived from the board name + accent."
  def identifier_badge(assigns) do
    assigns =
      assigns
      |> assign(:accent_css, accent_color(Map.get(assigns.board, :accent)))
      |> assign(:prefix, board_prefix(assigns.board.name))

    ~H"""
    <span
      aria-hidden="true"
      style={[
        "width: #{@size}px; height: #{@size}px; border-radius: 6px;",
        "background: #{@accent_css};",
        "display: inline-flex; align-items: center; justify-content: center;",
        "color: white; font-size: #{badge_font_size(@size)}px; font-weight: 700;",
        "font-family: var(--font-mono); letter-spacing: -0.02em; flex-shrink: 0;"
      ]}
    >
      {@prefix}
    </span>
    """
  end

  defp badge_font_size(size) when size <= 20, do: 9
  defp badge_font_size(_), do: 10.5

  defp accent_color(:orange), do: "var(--stride-orange)"
  defp accent_color(:ready), do: "var(--st-ready)"
  defp accent_color(:doing), do: "var(--st-doing)"
  defp accent_color(:violet), do: "var(--stride-violet)"
  defp accent_color(:backlog), do: "var(--st-backlog)"
  defp accent_color(:blocked), do: "var(--st-blocked)"
  defp accent_color(_other), do: "var(--ink-3)"

  defp board_prefix(name) when is_binary(name) do
    letters =
      name
      |> String.upcase()
      |> String.replace(~r/[^A-Z]/, "")

    letters
    |> String.slice(0, 3)
    |> String.pad_trailing(3, "?")
  end

  defp board_prefix(_), do: "???"

  @doc "Pill rendered when a board is AI-optimized."
  def ai_pill(assigns) do
    ~H"""
    <span
      class="ucase"
      style={[
        "display: inline-flex; align-items: center; gap: 3px;",
        "padding: 2px 6px; border-radius: 999px;",
        "background: var(--stride-violet-soft); color: var(--stride-violet-ink);",
        "font-size: 9px; font-weight: 600; letter-spacing: 0.04em;"
      ]}
    >
      {gettext("AI")}
    </span>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :tone, :string, required: true

  defp kv(assigns) do
    ~H"""
    <div style="display: flex; flex-direction: column; align-items: flex-start;">
      <span class="ucase" style="font-size: 9.5px;">{@label}</span>
      <span style={[
        "font-size: 14px; font-weight: 600; color: #{@tone};",
        "font-feature-settings: 'tnum'; letter-spacing: -0.02em;"
      ]}>
        {@value}
      </span>
    </div>
    """
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(s) when is_binary(s), do: String.trim(s) != ""
  defp present?(_), do: false
end
