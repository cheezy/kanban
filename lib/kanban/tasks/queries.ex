defmodule Kanban.Tasks.Queries do
  @moduledoc """
  Read-only query functions for tasks.

  Provides functions for listing, fetching, and searching tasks
  with various preloading strategies.
  """

  import Ecto.Query, warn: false

  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskComment
  alias Kanban.Tasks.TaskHistory

  @doc """
  Returns the list of tasks for a column, ordered by position.

  By default, excludes archived tasks. Pass `include_archived: true` to include them.
  """
  def list_tasks(column, opts \\ []) do
    include_archived = Keyword.get(opts, :include_archived, false)

    Task
    |> where([t], t.column_id == ^column.id)
    |> maybe_filter_archived(include_archived)
    |> order_by([t], t.position)
    |> preload(:assigned_to)
    |> Repo.all()
  end

  @doc """
  Returns tasks for a batch of columns, grouped by `column_id`.

  Issues a single query (one pool checkout) regardless of how many columns are
  requested. Tasks are ordered by `position` within each column's bucket and
  `:assigned_to` is preloaded — matching the single-column `list_tasks/2` shape.

  The returned map only contains keys for columns that have at least one task.
  Callers that need an entry for every requested column should merge against a
  seed map built from the column IDs.
  """
  def list_tasks_by_columns(columns, opts \\ []) do
    include_archived = Keyword.get(opts, :include_archived, false)
    column_ids = Enum.map(columns, & &1.id)

    case column_ids do
      [] ->
        %{}

      ids ->
        Task
        |> where([t], t.column_id in ^ids)
        |> maybe_filter_archived(include_archived)
        |> order_by([t], [t.column_id, t.position])
        |> preload(:assigned_to)
        |> Repo.all()
        |> Enum.group_by(& &1.column_id)
    end
  end

  @doc """
  Returns archived tasks for a column, sorted by archived_at descending.
  """
  def list_archived_tasks(column) do
    Task
    |> where([t], t.column_id == ^column.id)
    |> where([t], not is_nil(t.archived_at))
    |> order_by([t], desc: t.archived_at)
    |> preload(:assigned_to)
    |> Repo.all()
  end

  @doc """
  Returns all archived tasks for a board, sorted by archived_at descending.
  """
  def list_archived_tasks_for_board(board_id) do
    Task
    |> join(:inner, [t], c in assoc(t, :column))
    |> where([t, c], c.board_id == ^board_id)
    |> where([t], not is_nil(t.archived_at))
    |> order_by([t], desc: t.archived_at)
    |> preload(:assigned_to)
    |> Repo.all()
  end

  @doc """
  Returns an archived task scoped to a board, or `nil` if it does not
  exist, is not archived, or belongs to a different board.

  Used by authorization-sensitive callers that must not trust a
  client-supplied task id without verifying it belongs to the current
  board.
  """
  def get_archived_task_for_board(id, board_id) do
    Task
    |> join(:inner, [t], c in assoc(t, :column))
    |> where([t, c], t.id == ^id and c.board_id == ^board_id)
    |> where([t], not is_nil(t.archived_at))
    |> Repo.one()
  end

  @doc """
  Returns a task scoped to a board, or `nil` if it does not exist or
  belongs to a different board.

  Unlike `get_archived_task_for_board/2` this does not filter on
  `archived_at`, so callers can use it to authorize any task lookup that
  must be bounded by the current board.
  """
  def get_task_for_board(id, board_id) do
    Task
    |> join(:inner, [t], c in assoc(t, :column))
    |> where([t, c], t.id == ^id and c.board_id == ^board_id)
    |> Repo.one()
  end

  @doc """
  Gets a single task. Raises `Ecto.NoResultsError` if not found.
  """
  def get_task!(id) do
    Task
    |> Repo.get!(id)
    |> Repo.preload(:assigned_to)
  end

  @doc """
  Gets a single task with preloaded task histories ordered by most recent first.
  """
  def get_task_with_history!(id) do
    Task
    |> Repo.get!(id)
    |> Repo.preload(
      task_histories:
        from(h in TaskHistory,
          order_by: [desc: h.inserted_at],
          preload: [:from_user, :to_user]
        )
    )
  end

  @doc """
  Gets a single task with all related data preloaded for read-only view.
  """
  def get_task_for_view!(id) do
    task =
      Task
      |> Repo.get!(id)
      |> Repo.preload([
        :assigned_to,
        :column,
        :created_by,
        :completed_by,
        :reviewed_by,
        task_histories:
          from(h in TaskHistory,
            order_by: [desc: h.inserted_at],
            preload: [:from_user, :to_user]
          ),
        comments: from(c in TaskComment, order_by: [asc: c.inserted_at])
      ])

    if task.type == :goal do
      Repo.preload(task,
        children: from(t in Task, order_by: [asc: t.position], preload: [:column])
      )
    else
      task
    end
  end

  @doc """
  Gets a single task with all related data preloaded. Returns nil if not found.
  """
  def get_task_for_view(id) do
    case Repo.get(Task, id) do
      nil ->
        nil

      task ->
        task =
          Repo.preload(task, [
            :assigned_to,
            :column,
            :created_by,
            :completed_by,
            :reviewed_by,
            task_histories:
              from(h in TaskHistory,
                order_by: [desc: h.inserted_at],
                preload: [:from_user, :to_user]
              ),
            comments: from(c in TaskComment, order_by: [asc: c.inserted_at])
          ])

        if task.type == :goal do
          Repo.preload(task,
            children: from(t in Task, order_by: [asc: t.position], preload: [:column])
          )
        else
          task
        end
    end
  end

  @doc """
  Gets a task by its identifier with all associations preloaded.
  Returns nil if not found.
  """
  def get_task_by_identifier_for_view(identifier, column_ids) do
    case Task
         |> where([t], t.identifier == ^identifier and t.column_id in ^column_ids)
         |> limit(1)
         |> Repo.one() do
      nil ->
        nil

      task ->
        Repo.preload(task, [
          :assigned_to,
          :column,
          :created_by,
          :completed_by,
          :reviewed_by,
          task_histories:
            from(h in TaskHistory,
              order_by: [desc: h.inserted_at],
              preload: [:from_user, :to_user]
            ),
          comments: from(c in TaskComment, order_by: [asc: c.inserted_at])
        ])
    end
  end

  @doc """
  Returns the non-archived child tasks of a goal, scoped to a user's
  board access. The list is ordered by `position` and preloads
  `:assigned_to` and `:parent` so the caller can render owner avatars
  and the parent-goal chip without N+1 queries.

  Returns `[]` when:
    * the `goal_id` does not exist
    * the task at `goal_id` is not a goal (defense in depth)
    * the user has no access to the goal's board
    * the goal has no non-archived children

  This keeps the function safe for unauthenticated read-only board paths
  (which pass through `user_access: nil`) — they get an empty list
  rather than an authorization error.
  """
  def list_children_for_goal(user, goal_id) do
    case goal_with_board(goal_id) do
      {:ok, board_id} ->
        if user_has_access?(user, board_id) do
          children_query(goal_id) |> Repo.all()
        else
          []
        end

      :not_a_goal ->
        []

      :not_found ->
        []
    end
  end

  @doc """
  Returns the non-archived goals (type: :goal) on a board, ordered by
  identifier. Preloads `:assigned_to` so the index page can render owner
  avatars without N+1.
  """
  def list_goals_for_board(board_id) do
    from(t in Task,
      join: c in assoc(t, :column),
      where: c.board_id == ^board_id,
      where: t.type == :goal,
      where: is_nil(t.archived_at),
      order_by: [asc: t.identifier],
      preload: [:assigned_to]
    )
    |> Repo.all()
  end

  @doc """
  Counts completed tasks grouped by the agent that completed them.

  Returns one map per distinct non-nil `completed_by_agent`, shaped
  `%{agent_name: String.t(), completed_count: non_neg_integer()}`, ordered by
  `completed_count` descending (ties broken by `agent_name` ascending).

  All boards, all time — deliberately unscoped, since the admin surface that
  consumes it wants a global per-agent tally. Goals are excluded: a goal
  inherits a `completed_at` when its last child finishes, so counting them
  would double-count real work (the same `type != :goal` guard every
  board-level metric query uses — see D87).
  """
  def completed_task_counts_by_agent do
    from(t in Task,
      where: not is_nil(t.completed_by_agent),
      where: t.type != ^:goal,
      group_by: t.completed_by_agent,
      order_by: [desc: count(t.id), asc: t.completed_by_agent],
      select: %{agent_name: t.completed_by_agent, completed_count: count(t.id)}
    )
    |> Repo.all()
  end

  defp goal_with_board(goal_id) do
    query =
      from t in Task,
        join: c in assoc(t, :column),
        where: t.id == ^goal_id,
        select: %{type: t.type, board_id: c.board_id}

    case Repo.one(query) do
      nil -> :not_found
      %{type: :goal, board_id: board_id} -> {:ok, board_id}
      %{type: _other} -> :not_a_goal
    end
  end

  defp children_query(goal_id) do
    from t in Task,
      where: t.parent_id == ^goal_id,
      where: is_nil(t.archived_at),
      order_by: [asc: t.position],
      preload: [:assigned_to, :parent, :column]
  end

  defp user_has_access?(nil, _board_id), do: false

  defp user_has_access?(%{id: user_id}, board_id) do
    from(bu in Kanban.Boards.BoardUser,
      where: bu.user_id == ^user_id and bu.board_id == ^board_id,
      limit: 1
    )
    |> Repo.exists?()
  end

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

  defp maybe_filter_archived(query, false) do
    where(query, [t], is_nil(t.archived_at))
  end

  defp maybe_filter_archived(query, true), do: query
end
