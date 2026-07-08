defmodule KanbanWeb.TargetGoalManageRow do
  @moduledoc """
  Non-navigating table row for one goal on the Edit Target page, ending in an
  Assign/Unassign action button.

  Visually mirrors `KanbanWeb.TargetGoalRow` cell-for-cell — priority dot,
  G-prefixed identifier, truncated title, a per-goal
  `KanbanWeb.SegmentedProgressBar` (`:sm`) with an N-of-M (P%) count, and the
  owner cell (assignee avatar + name, or "unassigned") — but with two
  deliberate differences the manage table needs:

    1. The row is a plain `<div>` container, NOT a `<.link navigate=...>`, so it
       can legally host a button and never navigates.
    2. The trailing cell is a `<.button>` (from core_components) instead of the
       chevron. Its text (`label`) and `phx-click` event (`event`) are attrs, so
       the same component serves both the assigned and the assignable tables.

  Pure presentation: it consumes one `Kanban.Targets.goal_progress_detail/0`
  entry — `%{goal, flow, completed, total, percentage}` — and loads no data.
  The `goal` MUST carry its `:assigned_to` (for the owner cell), exactly as
  `Kanban.Targets.list_member_goal_details/2` and
  `list_assignable_goal_details/2` provide.
  """
  use KanbanWeb, :html

  import KanbanWeb.TaskVisuals

  alias KanbanWeb.Avatar
  alias KanbanWeb.SegmentedProgressBar

  @doc """
  Renders one goal as a non-navigating manage row.

  ## Attrs

    * `entry` — a `Kanban.Targets.goal_progress_detail/0` map:
      `%{goal: %Task{assigned_to: _, ...}, flow: %{done, review, doing, ready,
      backlog, total}, completed:, total:, percentage:}`. The percentage is
      re-derived here from `completed`/`total` (guarding `total == 0`).
      Required.
    * `event` — the `phx-click` event name emitted by the action button
      (e.g. `"assign_goal"` / `"unassign_goal"`). Required.
    * `label` — the action button's text, already translated by the caller
      (e.g. `gettext("Assign")` / `gettext("Unassign")`). Rendered as-is.
      Required.
  """
  attr :entry, :map, required: true
  attr :event, :string, required: true
  attr :label, :string, required: true

  def target_goal_manage_row(assigns) do
    assigns = derive_assigns(assigns)

    ~H"""
    <div
      id={"target-goal-manage-row-#{@goal_id}"}
      data-target-goal-manage-row
      style={[
        "display: grid; grid-template-columns: 22px 56px 1fr 220px 120px auto;",
        "align-items: center; gap: 10px;",
        "padding: 8px 14px; border-bottom: 1px solid var(--line);"
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

      <span style="display: inline-flex; justify-content: flex-end;">
        <.button type="button" phx-click={@event} phx-value-goal_id={@goal_id}>
          {@label}
        </.button>
      </span>
    </div>
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
    |> assign(:goal_id, goal.id)
    |> assign(:identifier, Map.get(goal, :identifier, ""))
    |> assign(:title, Map.get(goal, :title, ""))
    |> assign(:priority, Map.get(goal, :priority))
    |> assign(:flow, Map.get(entry, :flow, %{}))
    |> assign(:owner, pick_owner(goal))
    |> assign(:total, total)
    |> assign(:done, done)
    |> assign(:pct, percentage(done, total))
  end

  # Handles a real %User{} (has :name), nil, and %Ecto.Association.NotLoaded{}
  # (no :name) uniformly — mirrors KanbanWeb.TargetGoalRow.pick_owner/1.
  defp pick_owner(goal) do
    case Map.get(goal, :assigned_to) do
      %{name: _} = user -> user
      _ -> nil
    end
  end

  defp percentage(_done, 0), do: 0
  defp percentage(done, total), do: round(done / total * 100)
end
