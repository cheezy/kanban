defmodule Kanban.Tasks.Queries do
  @moduledoc """
  Read-only query functions for tasks.

  Provides functions for listing, fetching, and searching tasks
  with various preloading strategies.
  """

  import Ecto.Query, warn: false

  alias Kanban.Repo
  alias Kanban.Tasks.BoardFilters
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
    |> preload([:assigned_to, :labels])
    |> Repo.all()
  end

  @doc """
  Returns tasks for a batch of columns, grouped by `column_id`.

  Issues a single query (one pool checkout) regardless of how many columns are
  requested. Tasks are ordered by `position` within each column's bucket and
  `:assigned_to` and `:labels` are preloaded (one batched query each, never
  one per card) — matching the single-column `list_tasks/2` shape.

  The returned map only contains keys for columns that have at least one task.
  Callers that need an entry for every requested column should merge against a
  seed map built from the column IDs.

  Pass `filters: %Kanban.Tasks.BoardFilters{}` to narrow the result with the
  board filter bar's search and selectors (see `Kanban.Tasks.BoardFilters`).
  """
  def list_tasks_by_columns(columns, opts \\ []) do
    case Enum.map(columns, & &1.id) do
      [] -> %{}
      ids -> query_tasks_by_column_ids(ids, opts)
    end
  end

  defp query_tasks_by_column_ids(ids, opts) do
    Task
    |> where([t], t.column_id in ^ids)
    |> maybe_filter_archived(Keyword.get(opts, :include_archived, false))
    |> BoardFilters.apply_filters(Keyword.get(opts, :filters))
    |> order_by([t], [t.column_id, t.position])
    |> preload([:assigned_to, :labels])
    |> Repo.all()
    |> Enum.group_by(& &1.column_id)
  end

  @doc """
  Returns one keyset-paginated, filtered page of a board's non-archived tasks
  as `{tasks, next_id}`. Implemented in `Kanban.Tasks.PageQueries` (W2224).
  """
  defdelegate list_board_tasks_page(board_id, filters, opts), to: Kanban.Tasks.PageQueries

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
        :labels,
        task_histories:
          from(h in TaskHistory,
            order_by: [desc: h.inserted_at],
            preload: [:from_user, :to_user]
          ),
        comments: comments_with_author_query(asc: :inserted_at)
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
            :labels,
            task_histories:
              from(h in TaskHistory,
                order_by: [desc: h.inserted_at],
                preload: [:from_user, :to_user]
              ),
            comments: comments_with_author_query(asc: :inserted_at)
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
          :labels,
          task_histories:
            from(h in TaskHistory,
              order_by: [desc: h.inserted_at],
              preload: [:from_user, :to_user]
            ),
          comments: comments_with_author_query(asc: :inserted_at)
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
  Like `get_task_with_history!/1`, but also preloads comments newest-first
  (the other preloads in this module order comments ascending). The task views
  no longer use it: since W2210 both render `KanbanWeb.TaskLive.CommentThreadComponent`,
  which lists comments oldest-first through `Kanban.Tasks.list_comment_thread/2`.
  """
  def get_task_with_comments!(id) do
    id
    |> get_task_with_history!()
    |> Repo.preload(comments: comments_with_author_query(desc: :id))
  end

  # Every comment preload also loads `:author` so views can render the
  # author's name without an N+1 query per comment.
  defp comments_with_author_query(order_by) do
    from(c in TaskComment, order_by: ^order_by, preload: [:author])
  end

  @doc """
  Returns `{identifier, title, id}` tuples for the non-archived goals on a
  board, ordered by identifier, excluding `exclude_task_id` so a task is never
  offered as its own parent.

  Deliberately a lean select rather than `list_goals_for_board/1`: the
  parent-goal picker needs only these three columns, so it skips loading full
  structs and the `:assigned_to` preload.
  """
  def list_goal_choices_for_board(board_id, exclude_task_id \\ nil) do
    from(t in Task,
      join: c in assoc(t, :column),
      where: c.board_id == ^board_id,
      where: t.type == :goal,
      where: t.id != ^(exclude_task_id || 0),
      where: is_nil(t.archived_at),
      order_by: [asc: t.identifier],
      select: {t.identifier, t.title, t.id}
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

  defp maybe_filter_archived(query, false) do
    where(query, [t], is_nil(t.archived_at))
  end

  defp maybe_filter_archived(query, true), do: query
end
