defmodule KanbanWeb.GoalsStrip do
  @moduledoc """
  Horizontal strip of active-goal pills displayed above the kanban
  columns. Each pill shows the goal identifier, name, a segmented
  progress bar across the five status buckets (done / review / doing /
  ready / backlog), and the done/total count. An optional "unpromoted"
  pill surfaces goals that have not yet been promoted into the working
  flow.

  Mirrors the `GoalsStrip` JSX block at lines 267-336 of
  `design_handoff_stride/design_source/screens/board-kanban.jsx`.

  The strip hides itself entirely when the `goals` list is empty —
  no chrome, no "New goal" button — so a board with no goals does not
  introduce an empty band above the columns. The LiveView can surface
  a separate empty affordance if needed.

  ## Goal shape

  Each goal in the list is a map with these keys (`Map.get/3` is used
  throughout so partial maps degrade gracefully):

    * `:identifier` — display id (e.g., `"G7"`). Required for content.
    * `:name` — short label rendered next to the identifier. Required.
    * `:color`, `:ink` — accent + text colors. Default to the violet
      palette when absent.
    * `:flow` — `%{done, review, doing, ready, backlog, total}` integer
      counts driving the segmented progress bar.
    * `:promoted` — boolean. When false, the "unpromoted" badge is
      shown.
  """
  use KanbanWeb, :html

  @segment_order [:done, :review, :doing, :ready, :backlog]
  @default_color "var(--stride-violet)"
  @default_ink "var(--stride-violet-ink)"

  @doc """
  Renders the goals strip.

  ## Attrs

    * `goals` — list of goal maps (see module @moduledoc). Required.
    * `compact` — when true, tighter padding for embedded contexts.
      Default false.
  """
  attr :goals, :list, required: true
  attr :compact, :boolean, default: false

  def goals_strip(%{goals: []} = assigns) do
    ~H""
  end

  def goals_strip(assigns) do
    assigns =
      assigns
      |> assign(:count, length(assigns.goals))
      |> assign(:outer_padding, if(assigns.compact, do: "8px 14px", else: "10px 22px 12px"))

    ~H"""
    <div style={[
      "padding: #{@outer_padding};",
      "border-bottom: 1px solid var(--line);",
      "background: var(--surface-2);",
      "display: flex; align-items: center; gap: 10px;"
    ]}>
      <div style="display: flex; align-items: center; gap: 6px; flex-shrink: 0;">
        <.icon name="hero-flag" class="w-2.5 h-2.5" />
        <span class="ucase" style="font-size: 10px;">{gettext("Active goals")}</span>
        <span class="ident" style="font-size: 10.5px;">{@count}</span>
      </div>

      <div style="width: 1px; height: 18px; background: var(--line);"></div>

      <div style="display: flex; gap: 8px; flex-wrap: wrap; flex: 1; min-width: 0;">
        <.goal_pill :for={goal <- @goals} goal={goal} />
      </div>

      <button
        type="button"
        style={[
          "padding: 4px 8px; border-radius: 4px;",
          "background: transparent; border: 1px solid var(--line);",
          "color: var(--ink-2); font-size: 11px; font-weight: 500;",
          "display: inline-flex; align-items: center; gap: 5px; flex-shrink: 0;"
        ]}
      >
        <.icon name="hero-plus" class="w-2.5 h-2.5" />
        {gettext("New goal")}
      </button>
    </div>
    """
  end

  # --- Sub-renderers -------------------------------------------------------

  attr :goal, :map, required: true

  defp goal_pill(assigns) do
    color = Map.get(assigns.goal, :color, @default_color)
    ink = Map.get(assigns.goal, :ink, @default_ink)
    flow = Map.get(assigns.goal, :flow, %{})
    total = Map.get(flow, :total, 0)
    done = Map.get(flow, :done, 0)

    assigns =
      assigns
      |> assign(:color, color)
      |> assign(:ink, ink)
      |> assign(:flow, flow)
      |> assign(:total, total)
      |> assign(:done, done)
      |> assign(:promoted, Map.get(assigns.goal, :promoted, false))

    ~H"""
    <div style={[
      "display: inline-flex; align-items: center; gap: 8px;",
      "padding: 5px 10px 5px 8px;",
      "background: var(--surface);",
      "border: 1px solid #{@color};",
      "border-left: 3px solid #{@color};",
      "border-radius: 5px;"
    ]}>
      <span class="ident" style={"font-size: 10.5px; color: #{@ink}; font-weight: 600;"}>
        {Map.get(@goal, :identifier) || Map.get(@goal, :id)}
      </span>
      <span style="font-size: 12px; font-weight: 500; color: var(--ink);">
        {Map.get(@goal, :name) || Map.get(@goal, :short)}
      </span>

      <.segmented_bar flow={@flow} />

      <span style="font-size: 11px; font-family: var(--font-mono); color: var(--ink-3);">
        {@done}/{@total}
      </span>

      <span
        :if={not @promoted}
        style={[
          "font-size: 9.5px; padding: 0 5px; border-radius: 3px;",
          "background: var(--st-backlog-soft); color: var(--st-backlog);",
          "font-family: var(--font-mono); font-weight: 600;"
        ]}
      >
        {gettext("unpromoted")}
      </span>
    </div>
    """
  end

  attr :flow, :map, required: true

  defp segmented_bar(assigns) do
    segments =
      Enum.flat_map(@segment_order, fn status ->
        count = Map.get(assigns.flow, status, 0)
        if count > 0, do: [{status, count}], else: []
      end)

    assigns = assign(assigns, :segments, segments)

    ~H"""
    <div style={[
      "display: flex; height: 10px; width: 96px;",
      "border-radius: 2px; overflow: hidden;",
      "background: var(--surface-sunken);"
    ]}>
      <span
        :for={{status, count} <- @segments}
        title={"#{status}: #{count}"}
        style={[
          "flex: #{count};",
          "background: #{status_color(status)};",
          "opacity: #{if status == :done, do: 1, else: 0.85};"
        ]}
      >
      </span>
    </div>
    """
  end

  # --- Helpers -------------------------------------------------------------

  defp status_color(:done), do: "var(--st-done)"
  defp status_color(:review), do: "var(--st-review)"
  defp status_color(:doing), do: "var(--st-doing)"
  defp status_color(:ready), do: "var(--st-ready)"
  defp status_color(:backlog), do: "var(--st-backlog)"
end
