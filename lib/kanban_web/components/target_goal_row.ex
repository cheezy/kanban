defmodule KanbanWeb.TargetGoalRow do
  @moduledoc """
  Compact table row for one delivery-target member goal, rendered in the
  target drill-down goals table. Mirrors `KanbanWeb.GoalChildRow`'s CSS-grid
  layout: priority dot, G-prefixed identifier, truncated title, a per-goal
  `KanbanWeb.SegmentedProgressBar` (`:sm`) with an N-of-M (P%) count, the owner
  cell (assignee avatar + name, an agent-attribution fallback, or
  "unassigned"), and a chevron.

  The whole row is a `<.link navigate=...>` to the goal drill-down
  (`/boards/:board_id/goals/:goal_id`), built only from the goal's OWN
  `column.board_id` so it never points at a board outside the caller's scope.

  Pure presentation: it consumes one `Kanban.Targets.goal_progress_detail/0`
  entry from `get_target_progress/2` — `%{goal, flow, completed, total,
  percentage}` — and loads no data. The `goal` MUST carry its `:column` (for
  `board_id`) and `:assigned_to`, exactly as `get_target_progress/2` provides.
  """
  use KanbanWeb, :html

  import KanbanWeb.TaskVisuals

  alias KanbanWeb.Avatar
  alias KanbanWeb.AvatarPalette
  alias KanbanWeb.SegmentedProgressBar

  @doc """
  Renders one member-goal row.

  ## Attrs

    * `entry` — a `Kanban.Targets.goal_progress_detail/0` map:
      `%{goal: %Task{column: %{board_id: _}, ...}, flow: %{done, review,
      doing, ready, backlog, total}, completed:, total:, percentage:}`. The
      percentage is re-derived here from `completed`/`total` (guarding
      `total == 0`). Required.
  """
  attr :entry, :map, required: true

  def target_goal_row(assigns) do
    assigns = derive_assigns(assigns)

    ~H"""
    <.link
      navigate={@path}
      data-target-goal-row
      style={[
        "display: grid; grid-template-columns: 22px 56px 1fr 220px 120px 18px;",
        "align-items: center; gap: 10px;",
        "padding: 8px 14px; border-bottom: 1px solid var(--line);",
        "text-decoration: none; cursor: pointer;"
      ]}
    >
      <.priority_dot priority={@priority} />

      <span data-goal-col="identifier" class="ident" style="font-size: 11px; color: var(--ink-2);">
        {@identifier}
      </span>

      <span style={[
        "min-width: 0; font-size: 12.5px; font-weight: 500; color: var(--ink);",
        "overflow: hidden; text-overflow: ellipsis; white-space: nowrap;"
      ]}>
        {@title}
      </span>

      <span data-goal-col="progress" style="display: inline-flex; align-items: center; gap: 8px;">
        <SegmentedProgressBar.segmented_progress
          flow={@flow}
          size={:sm}
          aria_label={gettext("Goal progress by child status")}
        />
        <span class="ident" style="font-size: 11px; color: var(--ink-3); white-space: nowrap;">
          {gettext("%{done} of %{total} (%{pct}%)", done: @done, total: @total, pct: @pct)}
        </span>
      </span>

      <.owner_cell owner={@owner} />

      <span style="color: var(--ink-4); display: inline-flex; justify-content: flex-end;">
        <.icon name="hero-chevron-right" class="w-3 h-3" />
      </span>
    </.link>
    """
  end

  # --- Sub-components ----------------------------------------------------

  attr :owner, :map, default: nil

  defp owner_cell(%{owner: nil} = assigns) do
    ~H"""
    <span
      data-goal-col="owner"
      class="ident"
      style="font-size: 11px; color: var(--ink-3); font-style: italic;"
    >
      {gettext("unassigned")}
    </span>
    """
  end

  defp owner_cell(assigns) do
    assigns =
      assigns
      |> assign(:owner_label, owner_label(assigns.owner))
      |> assign(:owner_kind, owner_kind(assigns.owner))
      |> assign(:owner_palette, owner_palette(assigns.owner))

    ~H"""
    <span
      data-goal-col="owner"
      style="display: inline-flex; align-items: center; gap: 6px; font-size: 11.5px; min-width: 0;"
    >
      <Avatar.avatar kind={@owner_kind} name={@owner_label} palette={@owner_palette} size={16} />
      <span style="color: var(--ink-2); overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
        {@owner_label}
      </span>
    </span>
    """
  end

  defp owner_label(owner) do
    Map.get(owner, :name) || Map.get(owner, :email) || ""
  end

  defp owner_kind(owner), do: Map.get(owner, :kind, :human)

  # --- Assign derivation -------------------------------------------------

  defp derive_assigns(assigns) do
    entry = assigns.entry
    goal = entry.goal
    total = Map.get(entry, :total, 0)
    done = Map.get(entry, :completed, 0)

    assigns
    |> assign(:identifier, Map.get(goal, :identifier, ""))
    |> assign(:title, Map.get(goal, :title, ""))
    |> assign(:priority, Map.get(goal, :priority))
    |> assign(:flow, Map.get(entry, :flow, %{}))
    |> assign(:owner, pick_owner(goal))
    |> assign(:path, goal_path(goal))
    |> assign(:total, total)
    |> assign(:done, done)
    |> assign(:pct, percentage(done, total))
  end

  # Built ONLY from the goal's own column.board_id, so the row can never link
  # to a board outside the caller's scope. The goal carries :column per the
  # get_target_progress/2 contract.
  defp goal_path(goal) do
    board_id = goal.column.board_id
    ~p"/boards/#{board_id}/goals/#{goal.id}"
  end

  # Handles a real %User{} (has :name), nil, and %Ecto.Association.NotLoaded{}
  # (no :name) uniformly — mirrors KanbanWeb.TargetGoalManageRow.pick_owner/1.
  # When no user is assigned, falls back to agent attribution (D132):
  # completed_by_agent wins over created_by_agent, and blank strings are
  # skipped per field — the same semantics as
  # KanbanWeb.GoalLive.Show.agents_from/1.
  defp pick_owner(goal) do
    case Map.get(goal, :assigned_to) do
      %{name: _} = user -> user
      _ -> agent_owner(goal)
    end
  end

  defp agent_owner(goal) do
    case agent_name(Map.get(goal, :completed_by_agent)) ||
           agent_name(Map.get(goal, :created_by_agent)) do
      nil -> nil
      agent -> %{kind: :agent, name: agent, palette: AvatarPalette.for_agent(agent)}
    end
  end

  defp agent_name(name) when is_binary(name) and name != "", do: name
  defp agent_name(_), do: nil

  defp percentage(_done, 0), do: 0
  defp percentage(done, total), do: round(done / total * 100)
end
