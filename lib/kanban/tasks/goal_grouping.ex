defmodule Kanban.Tasks.GoalGrouping do
  @moduledoc """
  Pure, in-memory ordering and grouping of tasks by goal: the board's
  goal-hierarchy column order (`sort_by_goal_hierarchy/1`) and the archive's
  goal groups (`group_rows_by_goal/1`). Neither touches the database.

  Extracted from `Kanban.Tasks.Queries` so that module stays below the
  500-line guideline; `Kanban.Tasks` delegates both functions here.
  """

  alias Kanban.Tasks.Task

  @doc """
  Sorts tasks so standalone tasks (no parent, not a goal) appear first,
  followed by goals in ascending identifier order with their children
  listed directly underneath each goal.
  """
  def sort_by_goal_hierarchy(tasks) do
    by_parent = Enum.group_by(tasks, & &1.parent_id)
    goals = collect_sorted_goals(tasks)
    goal_ids = MapSet.new(goals, & &1.id)
    standalone = collect_standalone(tasks, goal_ids)

    standalone ++ Enum.flat_map(goals, &goal_with_children(&1, by_parent))
  end

  defp collect_sorted_goals(tasks) do
    tasks
    |> Enum.filter(&(&1.type == :goal))
    |> Enum.sort_by(&sort_key/1, NaiveDateTime)
  end

  defp collect_standalone(tasks, goal_ids) do
    tasks
    |> Enum.filter(&standalone?(&1, goal_ids))
    |> Enum.sort_by(&sort_key/1, NaiveDateTime)
  end

  defp standalone?(%{type: :goal}, _goal_ids), do: false
  defp standalone?(%{parent_id: nil}, _goal_ids), do: true
  defp standalone?(%{parent_id: parent_id}, goal_ids), do: not MapSet.member?(goal_ids, parent_id)

  defp goal_with_children(goal, by_parent) do
    children =
      by_parent
      |> Map.get(goal.id, [])
      |> Enum.sort_by(&sort_key/1, NaiveDateTime)

    [goal | children]
  end

  @doc """
  Groups archived rows into a leading "Tasks Without Goals" group followed
  by per-goal groups.

  Each group is a map `%{key, kind, goal, goal_row, child_rows}`:

    * `kind` is `:goal` or `:no_goal`.
    * Goal groups are keyed `"goal:<id>"`. `goal` is the goal struct.
      `goal_row` is the goal's own archived row when it was archived this
      month (so the caller can render that row with the chevron and skip a
      separate header line), otherwise `nil`. `child_rows` holds only the
      children (oldest first). When a child's goal was archived in a
      different month — so the goal task is absent from `tasks` —
      `goal_row` is `nil` and `goal` is synthesized from the child's
      preloaded `:parent` association.
    * The `:no_goal` group (keyed `"no_goal"`) has `goal` and `goal_row`
      `nil` and collects standalone tasks (no parent, not a goal) in
      `child_rows`. It is always first and is omitted entirely when there
      are no standalone rows.

  Pure in-memory shaping over already-loaded rows — no queries. Relies on
  the `:parent` preload from `Kanban.Archives.list_archived_for_board/1`.
  """
  def group_rows_by_goal(tasks) do
    by_parent = Enum.group_by(tasks, & &1.parent_id)

    no_goal_group(collect_no_goal(by_parent)) ++ build_goal_groups(tasks, by_parent)
  end

  defp build_goal_groups(tasks, by_parent) do
    present_by_id = present_goals_by_id(tasks)

    tasks
    |> goal_ids(present_by_id)
    |> Enum.map(&build_goal_group(&1, present_by_id, by_parent))
    |> Enum.sort_by(&group_sort_key/1, NaiveDateTime)
  end

  defp present_goals_by_id(tasks) do
    tasks |> Enum.filter(&(&1.type == :goal)) |> Map.new(&{&1.id, &1})
  end

  defp goal_ids(tasks, present_by_id) do
    child_parent_ids = tasks |> Enum.filter(&child?/1) |> Enum.map(& &1.parent_id)

    (Map.keys(present_by_id) ++ child_parent_ids) |> Enum.uniq()
  end

  defp build_goal_group(goal_id, present_by_id, by_parent) do
    children =
      by_parent
      |> Map.get(goal_id, [])
      |> Enum.reject(&(&1.type == :goal))
      |> Enum.sort_by(&sort_key/1, NaiveDateTime)

    case Map.get(present_by_id, goal_id) do
      %Task{} = goal ->
        %{key: "goal:#{goal_id}", kind: :goal, goal: goal, goal_row: goal, child_rows: children}

      _ ->
        %{
          key: "goal:#{goal_id}",
          kind: :goal,
          goal: synthesized_goal(children),
          goal_row: nil,
          child_rows: children
        }
    end
  end

  defp synthesized_goal([%{parent: %Task{} = parent} | _]), do: parent
  defp synthesized_goal(_), do: nil

  defp collect_no_goal(by_parent) do
    by_parent
    |> Map.get(nil, [])
    |> Enum.reject(&(&1.type == :goal))
    |> Enum.sort_by(&sort_key/1, NaiveDateTime)
  end

  defp no_goal_group([]), do: []

  defp no_goal_group(rows) do
    [%{key: "no_goal", kind: :no_goal, goal: nil, goal_row: nil, child_rows: rows}]
  end

  defp child?(%{type: :goal}), do: false
  defp child?(%{parent_id: nil}), do: false
  defp child?(_), do: true

  defp group_sort_key(%{goal: %{inserted_at: %NaiveDateTime{} = ts}}), do: ts
  defp group_sort_key(%{child_rows: [first | _]}), do: sort_key(first)
  defp group_sort_key(_), do: ~N[1970-01-01 00:00:00]

  # Tasks within the goal-hierarchy columns sort by creation time (oldest
  # first). Using `inserted_at` rather than parsing the identifier sidesteps
  # the natural-vs-lexicographic-sort headache and stays stable when an
  # identifier is renumbered or backfilled.
  defp sort_key(%{inserted_at: %NaiveDateTime{} = ts}), do: ts
  defp sort_key(_), do: ~N[1970-01-01 00:00:00]
end
