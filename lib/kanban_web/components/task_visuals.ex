defmodule KanbanWeb.TaskVisuals do
  @moduledoc """
  Shared visual primitives for task and goal cards — the priority dot, the
  task-type icon, the status pill, and the owner-palette / AI-generated
  helpers behind them.

  Extracted from the near-identical private copies that previously lived in
  `KanbanWeb.GoalCard`, `KanbanWeb.GoalChildRow`, `KanbanWeb.GoalProgressHeader`,
  `KanbanWeb.TaskCard`, `KanbanWeb.TaskDetailHeader`,
  `KanbanWeb.TaskMetadataGrid`, and `KanbanWeb.TaskLive.ViewComponent` (W1081).
  Where the copies had intentionally diverged the difference is an explicit
  attribute, never silently unified:

    * `type_icon/1` takes `icon_class` — cards render `"w-3 h-3"`, detail
      headers the default `"w-4 h-4"`. Sizes stay literal class strings at the
      call sites so Tailwind v4's `source(none)` static scanner keeps them.
    * `status_pill/1` requires a `variant` — `:compact` (goal child rows,
      1px vertical padding), `:detail` (metadata grid and detail header,
      bordered with letter-spacing), and `:base` (task view band, plain
      2px padding).
  """
  use KanbanWeb, :html

  alias KanbanWeb.AvatarPalette
  alias KanbanWeb.TaskTokens

  attr :priority, :atom, required: true

  @doc """
  Renders the 6px priority dot colored by `KanbanWeb.TaskTokens.priority_color/1`.
  """
  def priority_dot(assigns) do
    assigns = assign(assigns, :color, TaskTokens.priority_color(assigns.priority))

    ~H"""
    <span
      aria-hidden="true"
      style={[
        "width: 6px; height: 6px; border-radius: 50%;",
        "background: #{@color}; flex-shrink: 0;"
      ]}
    >
    </span>
    """
  end

  attr :type, :atom, required: true
  attr :icon_class, :string, default: "w-4 h-4"

  @doc """
  Renders the hero icon for a task type — bug for defects, flag for goals,
  document for work. Pass `icon_class="w-3 h-3"` for the compact card size.
  """
  def type_icon(%{type: :defect} = assigns) do
    ~H"""
    <span style="color: var(--st-blocked); display: inline-flex;">
      <.icon name="hero-bug-ant" class={@icon_class} />
    </span>
    """
  end

  def type_icon(%{type: :goal} = assigns) do
    ~H"""
    <span style="color: var(--stride-violet); display: inline-flex;">
      <.icon name="hero-flag" class={@icon_class} />
    </span>
    """
  end

  def type_icon(assigns) do
    # Default: :work
    ~H"""
    <span style="color: var(--st-ready); display: inline-flex;">
      <.icon name="hero-document-text" class={@icon_class} />
    </span>
    """
  end

  attr :status, :atom, required: true
  attr :variant, :atom, required: true, values: [:base, :compact, :detail]

  @doc """
  Renders the status pill (label, soft background, status ink) in one of the
  three byte-preserved variants the call sites had developed.
  """
  def status_pill(assigns) do
    {style_head, style_tail} = pill_style(assigns.variant)

    assigns =
      assigns
      |> assign(:bg, TaskTokens.status_soft(assigns.status))
      |> assign(:fg, TaskTokens.status_ink(assigns.status))
      |> assign(:label, TaskTokens.status_label(assigns.status))
      |> assign(:style_head, style_head)
      |> assign(:style_tail, style_tail)

    ~H"""
    <span style={[
      @style_head,
      "background: #{@bg}; color: #{@fg};",
      @style_tail
    ]}>
      {@label}
    </span>
    """
  end

  # The style fragments are copied byte-for-byte from the original copies,
  # split around the background/color line so the rendered style attribute
  # keeps the exact original property order per variant.
  defp pill_style(:compact) do
    {[
       "display: inline-flex; align-items: center;",
       "padding: 1px 7px; border-radius: 999px;"
     ],
     [
       "font-size: 10.5px; font-weight: 600;"
     ]}
  end

  defp pill_style(:detail) do
    {[
       "display: inline-flex; align-items: center; gap: 3px;",
       "padding: 2px 7px; border-radius: 999px;"
     ],
     [
       "border: 1px solid transparent;",
       "font-size: 10.5px; font-weight: 600; letter-spacing: -0.005em;"
     ]}
  end

  defp pill_style(:base) do
    {[
       "display: inline-flex; align-items: center;",
       "padding: 2px 7px; border-radius: 999px;"
     ],
     [
       "font-size: 10.5px; font-weight: 600;"
     ]}
  end

  @doc """
  Resolves the avatar palette for an owner map: an explicit binary `:palette`
  wins, agents fall back to `AvatarPalette.for_agent/1` by name, everyone
  else to `AvatarPalette.for_human/1` by id.
  """
  def owner_palette(owner) do
    case Map.get(owner, :palette) do
      palette when is_binary(palette) -> palette
      _ -> resolve_owner_palette(owner)
    end
  end

  defp resolve_owner_palette(owner) do
    case Map.get(owner, :kind) do
      :agent -> owner |> Map.get(:name) |> AvatarPalette.for_agent()
      _ -> owner |> Map.get(:id) |> AvatarPalette.for_human()
    end
  end

  @doc """
  True when the task or goal map carries either AI-generated flag.
  """
  def ai_generated?(item) do
    Map.get(item, :ai_generated?, false) || Map.get(item, :ai_generated, false)
  end
end
