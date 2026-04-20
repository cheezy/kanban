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
  def get_task_by_identifier_for_view!(identifier, column_ids) do
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
  Sorts tasks so standalone tasks (no parent, not a goal) appear first,
  followed by goals in ascending identifier order with their children
  listed directly underneath each goal.
  """
  def sort_by_goal_hierarchy(tasks) do
    by_parent = Enum.group_by(tasks, & &1.parent_id)
    standalone = tasks |> Enum.filter(&standalone?/1) |> Enum.sort_by(& &1.identifier)
    goals = tasks |> Enum.filter(&(&1.type == :goal)) |> Enum.sort_by(& &1.identifier)

    standalone ++ Enum.flat_map(goals, &goal_with_children(&1, by_parent))
  end

  defp standalone?(%{parent_id: nil, type: type}) when type != :goal, do: true
  defp standalone?(_task), do: false

  defp goal_with_children(goal, by_parent) do
    children = by_parent |> Map.get(goal.id, []) |> Enum.sort_by(& &1.identifier)
    [goal | children]
  end

  defp maybe_filter_archived(query, false) do
    where(query, [t], is_nil(t.archived_at))
  end

  defp maybe_filter_archived(query, true), do: query
end
