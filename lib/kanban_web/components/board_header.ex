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
          <.ai_pill :if={Map.get(@board, :ai_optimized_board, false)} />
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
        <.kv label={gettext("in flight")} value={@in_flight} tone="var(--st-doing)" />
        <.kv label={gettext("in review")} value={@in_review} tone="var(--st-review)" />
        <.kv label={gettext("shipped")} value={@shipped} tone="var(--st-done)" />
      </div>
    </div>
    """
  end

  defp ai_pill(assigns) do
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
