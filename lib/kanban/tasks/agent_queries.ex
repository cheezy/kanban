defmodule Kanban.Tasks.AgentQueries do
  @moduledoc """
  Agent-specific task discovery queries.

  Provides read-only queries used by AI agents to find available work,
  filter by capabilities, check for file conflicts, and discover tasks
  by technology or verification steps.
  """

  import Ecto.Query, warn: false

  alias Kanban.Columns.Column
  alias Kanban.Repo
  alias Kanban.Tasks.Task

  @doc """
  Returns all tasks that modify a specific file.

  Uses PostgreSQL's @> (contains) operator with GIN index for fast lookups.
  """
  def get_tasks_modifying_file(file_path) do
    from(t in Task,
      where:
        fragment(
          "EXISTS (SELECT 1 FROM jsonb_array_elements(?) elem WHERE elem->>'file_path' = ?)",
          t.key_files,
          ^file_path
        )
    )
    |> Repo.all()
  end

  @doc """
  Returns all tasks that require a specific technology.

  Uses PostgreSQL's array contains operator.
  """
  def get_tasks_requiring_technology(tech) do
    from(t in Task,
      where: fragment("? @> ?", t.technology_requirements, ^[tech])
    )
    |> Repo.all()
  end

  @doc """
  Returns all tasks with command-based verification steps.
  """
  def get_tasks_with_automated_verification do
    from(t in Task,
      where:
        fragment(
          ~s|? @> '[{"step_type": "command"}]'::jsonb|,
          t.verification_steps
        )
    )
    |> Repo.all()
  end

  @doc """
  Gets the next task for an AI agent to work on.

  Returns the next available task from the "Ready" column using optimized filtering:
  1. Tasks in "Ready" column (indexed lookup)
  2. Agent has all required capabilities (array operation)
  3. All dependencies completed (subquery check)
  4. No key_file conflicts with tasks in "Doing" or "Review" (JSONB comparison)
  5. Ordered by priority (descending), then position (ascending)

  Has status "open" (not claimed) OR has expired claim.
  Returns nil if no task available.
  """
  def get_next_task(agent_capabilities \\ [], board_id) do
    now = DateTime.utc_now()

    completed_task_identifiers =
      from(t in Task,
        join: c in assoc(t, :column),
        where: c.board_id == ^board_id,
        where: t.status == :completed,
        select: t.identifier
      )

    conflicting_task_ids =
      from(t in Task,
        join: c in Column,
        on: t.column_id == c.id,
        where: c.name in ["Doing", "Review"],
        where: c.board_id == ^board_id,
        where: t.status == :in_progress,
        select: %{
          id: t.id,
          key_files: t.key_files
        }
      )
      |> Repo.all()

    query =
      from(t in Task,
        join: c in Column,
        on: t.column_id == c.id,
        where: c.name == "Ready",
        where: c.board_id == ^board_id,
        where: t.type in [:work, :defect],
        where: t.status == :open or (t.status == :in_progress and t.claim_expires_at < ^now),
        order_by: [
          desc:
            fragment(
              "CASE ? WHEN 'critical' THEN 4 WHEN 'high' THEN 3 WHEN 'medium' THEN 2 WHEN 'low' THEN 1 ELSE 0 END",
              t.priority
            ),
          asc: t.position
        ],
        preload: [:column, :assigned_to, :created_by]
      )

    query =
      if agent_capabilities == [] do
        from(t in query)
      else
        from(t in query,
          where:
            fragment("cardinality(?)", t.required_capabilities) == 0 or
              fragment("?::varchar[] @> ?", ^agent_capabilities, t.required_capabilities)
        )
      end

    query =
      from(t in query,
        where:
          fragment("cardinality(?)", t.dependencies) == 0 or
            fragment(
              "NOT EXISTS (
                SELECT 1
                FROM unnest(?) AS dep_id
                WHERE dep_id NOT IN (?)
              )",
              t.dependencies,
              subquery(completed_task_identifiers)
            )
      )

    tasks = Repo.all(query)

    Enum.find(tasks, fn task ->
      not has_key_file_conflict?(task, conflicting_task_ids)
    end)
  end

  @doc """
  Gets a specific task for claiming by identifier, applying the same filters as get_next_task.
  """
  def get_specific_task_for_claim(identifier, agent_capabilities, board_id) do
    now = DateTime.utc_now()

    completed_task_identifiers =
      from(t in Task,
        join: c in assoc(t, :column),
        where: c.board_id == ^board_id,
        where: t.status == :completed,
        select: t.identifier
      )

    query =
      from(t in Task,
        join: c in Column,
        on: t.column_id == c.id,
        where: t.identifier == ^identifier,
        where: c.board_id == ^board_id,
        where: c.name == "Ready",
        where: t.type in [:work, :defect],
        where: t.status == :open or (t.status == :in_progress and t.claim_expires_at < ^now),
        preload: [:column, :assigned_to, :created_by]
      )

    query =
      if agent_capabilities == [] do
        from(t in query)
      else
        from(t in query,
          where:
            fragment("cardinality(?)", t.required_capabilities) == 0 or
              fragment("?::varchar[] @> ?", ^agent_capabilities, t.required_capabilities)
        )
      end

    query =
      from(t in query,
        where:
          fragment("cardinality(?)", t.dependencies) == 0 or
            fragment(
              "NOT EXISTS (
                SELECT 1
                FROM unnest(?) AS dep_id
                WHERE dep_id NOT IN (?)
              )",
              t.dependencies,
              subquery(completed_task_identifiers)
            )
      )

    Repo.one(query)
  end

  defp has_key_file_conflict?(task, conflicting_tasks) do
    case extract_file_paths(task.key_files) do
      [] -> false
      task_paths -> Enum.any?(conflicting_tasks, &files_overlap?(task_paths, &1.key_files))
    end
  end

  defp extract_file_paths(nil), do: []
  defp extract_file_paths([]), do: []

  defp extract_file_paths(key_files) do
    key_files
    |> Enum.map(fn kf -> kf.file_path end)
    |> Enum.reject(&is_nil/1)
  end

  defp files_overlap?(_task_paths, nil), do: false
  defp files_overlap?(_task_paths, []), do: false

  defp files_overlap?(task_paths, conflict_key_files) do
    conflict_paths = extract_file_paths(conflict_key_files)
    Enum.any?(task_paths, fn path -> path in conflict_paths end)
  end
end
