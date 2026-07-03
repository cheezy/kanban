defmodule KanbanWeb.BoardLive.Goals do
  @moduledoc """
  Pure goals-strip computation for `KanbanWeb.BoardLive.Show`, extracted from the
  LiveView (W1446). Builds the active-goals list `KanbanWeb.GoalsStrip` renders,
  the per-goal chip lookup, the per-goal progress totals, and the set of backlog
  goals eligible for "promote children to Ready."

  No socket access. `compute_goal_progress/2` is the one function that touches the
  database (`Tasks.get_task_children/2` per goal); the rest operate on the
  in-memory `tasks_by_column` map. `compute_active_goals/4` calls back into
  `KanbanWeb.BoardLive.Show.column_status/1`, which stays in the LiveView because
  the template uses it directly too.
  """

  alias Kanban.Tasks
  alias KanbanWeb.BoardLive.Show

  # Build the list of active goals shaped for KanbanWeb.GoalsStrip.
  # Each entry has :identifier, :name, :color, :ink, :promoted plus a
  # :flow map of segmented child-task counts per status. The list is
  # sorted by identifier so the strip's order is stable across refreshes.
  @doc "Builds the active-goals list for the goals strip, sorted by inserted_at."
  def compute_active_goals(tasks_by_column, columns, goals_by_id, backlog_promotable) do
    status_by_column_id = Map.new(columns, fn col -> {col.id, Show.column_status(col.name)} end)

    goals_by_id
    |> Enum.map(&build_active_goal(&1, tasks_by_column, status_by_column_id, backlog_promotable))
    |> Enum.sort_by(& &1.inserted_at, NaiveDateTime)
  end

  defp build_active_goal({goal_id, info}, tasks_by_column, status_by_column_id, promotable) do
    info
    |> Map.put(:name, info.short)
    |> Map.put(:flow, goal_flow_for(goal_id, tasks_by_column, status_by_column_id))
    |> Map.put(:promoted, not MapSet.member?(promotable, goal_id))
  end

  # Sums up child-task counts per status bucket for one goal, plus the
  # total. Children are tasks whose parent_id == goal_id; their column's
  # status atom (via column_status/1) drives which bucket they land in.
  defp goal_flow_for(goal_id, tasks_by_column, status_by_column_id) do
    empty = %{done: 0, review: 0, doing: 0, ready: 0, backlog: 0, total: 0}

    Enum.reduce(tasks_by_column, empty, fn {column_id, tasks}, acc ->
      status = Map.get(status_by_column_id, column_id, :backlog)
      n = Enum.count(tasks, fn task -> task.parent_id == goal_id end)

      if n > 0 do
        acc
        |> Map.update!(status, &(&1 + n))
        |> Map.update!(:total, &(&1 + n))
      else
        acc
      end
    end)
  end

  # Build a lookup map keyed by goal task id, value being the small
  # chip-shaped map TaskCard's goal_chip reads: identifier, short name,
  # and a deterministic accent color/ink derived from the goal id.
  @doc "Builds the goal-id => chip-map lookup with deterministic accent colors."
  def compute_goals_by_id(tasks_by_column) do
    tasks_by_column
    |> Map.values()
    |> List.flatten()
    |> Enum.filter(&(&1.type == :goal))
    |> Map.new(fn goal ->
      {goal.id,
       %{
         id: goal.id,
         identifier: goal.identifier,
         short: goal.title,
         color: goal_accent_color(goal.id),
         ink: goal_accent_ink(goal.id),
         inserted_at: goal.inserted_at
       }}
    end)
  end

  # The accent color is derived purely from `rem(goal_id, 6)` indexing into this
  # fixed list. The ELEMENT ORDER of @goal_accents is the contract: reordering,
  # adding, or removing an entry silently reassigns colors to every existing
  # goal. Keep it byte-for-byte identical.
  @goal_accents [
    {"var(--stride-orange)", "var(--stride-orange-ink)"},
    {"var(--st-ready)", "var(--st-ready)"},
    {"var(--st-doing)", "var(--st-doing)"},
    {"var(--stride-violet)", "var(--stride-violet-ink)"},
    {"var(--st-done)", "var(--st-done)"},
    {"var(--st-review)", "var(--st-review)"}
  ]

  @doc "Deterministic accent color for a goal id (rem(id, 6) into @goal_accents)."
  def goal_accent_color(id) when is_integer(id) do
    {color, _ink} = Enum.at(@goal_accents, rem(id, length(@goal_accents)))
    color
  end

  def goal_accent_color(_), do: "var(--stride-violet)"

  @doc "Deterministic accent ink for a goal id (rem(id, 6) into @goal_accents)."
  def goal_accent_ink(id) when is_integer(id) do
    {_color, ink} = Enum.at(@goal_accents, rem(id, length(@goal_accents)))
    ink
  end

  def goal_accent_ink(_), do: "var(--stride-violet-ink)"

  @doc "Computes per-goal progress totals (queries children per goal)."
  def compute_goal_progress(tasks_by_column, board_id) do
    tasks_by_column
    |> Enum.flat_map(fn {_column_id, tasks} -> tasks end)
    |> Enum.filter(&(&1.type == :goal))
    |> Enum.into(%{}, fn goal ->
      children = Tasks.get_task_children(goal.id, board_id)
      total = length(children)
      completed = Enum.count(children, &(&1.status == :completed))
      percentage = if total > 0, do: round(completed / total * 100), else: 0
      {goal.id, %{total: total, completed: completed, percentage: percentage}}
    end)
  end

  @doc "Returns the MapSet of backlog goal ids that have backlog children."
  def compute_backlog_promotable_goals(columns, tasks_by_column) do
    case Enum.find(columns, fn col -> col.name == "Backlog" end) do
      nil -> MapSet.new()
      backlog_col -> promotable_goal_ids(Map.get(tasks_by_column, backlog_col.id, []))
    end
  end

  defp promotable_goal_ids(backlog_tasks) do
    backlog_child_parent_ids = backlog_child_parent_ids(backlog_tasks)

    backlog_tasks
    |> Enum.filter(fn t ->
      t.type == :goal and MapSet.member?(backlog_child_parent_ids, t.id)
    end)
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  defp backlog_child_parent_ids(backlog_tasks) do
    backlog_tasks
    |> Enum.reject(&is_nil(&1.parent_id))
    |> Enum.map(& &1.parent_id)
    |> MapSet.new()
  end
end
