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

  The strip renders goal pills only — it carries no "New goal"
  affordance of its own. The single create entry point lives in the
  always-visible board page header actions (`BoardLive.Show`,
  `/boards/:id/goals/new`), so it is reachable whether or not the board
  has any goals and never appears twice (mirroring the
  `KanbanWeb.TargetsStrip` pattern). The strip hides itself entirely
  when the `goals` list is empty — no chrome — so a board with no goals
  does not introduce an empty band above the columns.

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

  alias KanbanWeb.SegmentedProgressBar

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
  attr :board, :map, default: nil

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
        <.goal_pill :for={goal <- @goals} goal={goal} board={@board} />
      </div>
    </div>
    """
  end

  # --- Sub-renderers -------------------------------------------------------

  attr :goal, :map, required: true
  attr :board, :map, default: nil

  defp goal_pill(assigns) do
    color = Map.get(assigns.goal, :color, @default_color)
    ink = Map.get(assigns.goal, :ink, @default_ink)
    flow = Map.get(assigns.goal, :flow, %{})
    total = Map.get(flow, :total, 0)
    done = Map.get(flow, :done, 0)
    href = navigate_href(assigns.board, assigns.goal)

    assigns =
      assigns
      |> assign(:color, color)
      |> assign(:ink, ink)
      |> assign(:flow, flow)
      |> assign(:total, total)
      |> assign(:done, done)
      |> assign(:promoted, Map.get(assigns.goal, :promoted, false))
      |> assign(:href, href)

    ~H"""
    <.link
      :if={@href}
      navigate={@href}
      style={pill_style(@color)}
      data-goal-pill
      aria-label={gettext("Open goal %{id}", id: Map.get(@goal, :identifier))}
    >
      <.goal_pill_body
        goal={@goal}
        ink={@ink}
        flow={@flow}
        done={@done}
        total={@total}
        promoted={@promoted}
      />
    </.link>
    <div :if={is_nil(@href)} style={pill_style(@color)} data-goal-pill>
      <.goal_pill_body
        goal={@goal}
        ink={@ink}
        flow={@flow}
        done={@done}
        total={@total}
        promoted={@promoted}
      />
    </div>
    """
  end

  attr :goal, :map, required: true
  attr :ink, :string, required: true
  attr :flow, :map, required: true
  attr :done, :integer, required: true
  attr :total, :integer, required: true
  attr :promoted, :boolean, required: true

  defp goal_pill_body(assigns) do
    ~H"""
    <span class="ident" style={"font-size: 10.5px; color: #{@ink}; font-weight: 600;"}>
      {Map.get(@goal, :identifier) || Map.get(@goal, :id)}
    </span>
    <span style="font-size: 12px; font-weight: 500; color: var(--ink);">
      {Map.get(@goal, :name) || Map.get(@goal, :short)}
    </span>

    <SegmentedProgressBar.segmented_progress flow={@flow} size={:sm} />

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
    """
  end

  defp pill_style(color) do
    [
      "display: inline-flex; align-items: center; gap: 8px;",
      "padding: 5px 10px 5px 8px;",
      "background: var(--surface);",
      "border: 1px solid #{color};",
      "border-left: 3px solid #{color};",
      "border-radius: 5px;",
      "text-decoration: none;"
    ]
  end

  defp navigate_href(nil, _goal), do: nil

  defp navigate_href(board, goal) do
    goal_id = Map.get(goal, :id)
    board_id = Map.get(board, :id)

    if goal_id && board_id do
      "/boards/#{board_id}/goals/#{goal_id}"
    end
  end
end
