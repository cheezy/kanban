defmodule Kanban.Tasks.Compliance do
  @moduledoc """
  Read-only compliance and workflow-step analytics queries scoped by board.

  Aggregates `Kanban.Tasks.Task.workflow_steps` (JSONB array) across all tasks
  on a board. All aggregation happens server-side via Postgres JSONB operators
  to avoid pulling full task rows into Elixir.

  This module is the seam between the database and the dashboard LiveView —
  LiveViews call these functions rather than issuing Ecto queries directly.
  """

  import Ecto.Query, warn: false

  alias Kanban.Repo
  alias Kanban.Tasks.Task

  @dispatch_rates_sql """
  SELECT elem->>'name' AS step_name,
         COUNT(*) AS total,
         COUNT(*) FILTER (WHERE (elem->>'dispatched')::boolean IS TRUE) AS dispatched
  FROM tasks t
  JOIN columns c ON c.id = t.column_id
  CROSS JOIN LATERAL jsonb_array_elements(t.workflow_steps) AS elem
  WHERE c.board_id = $1
    AND elem->>'name' IS NOT NULL
  GROUP BY elem->>'name'
  """

  @skip_reasons_sql """
  SELECT COALESCE(elem->>'reason', '') AS reason,
         COUNT(*) AS count
  FROM tasks t
  JOIN columns c ON c.id = t.column_id
  CROSS JOIN LATERAL jsonb_array_elements(t.workflow_steps) AS elem
  WHERE c.board_id = $1
    AND (elem->>'skipped')::boolean IS TRUE
  GROUP BY COALESCE(elem->>'reason', '')
  """

  @doc """
  Returns a map of step name to dispatch rate (0.0 to 100.0) across all tasks
  on the given board.

  A step is considered "dispatched" when its `"dispatched"` key is `true`.
  Steps with no `"name"` key are ignored. Tasks with an empty `workflow_steps`
  array contribute nothing.
  """
  def step_dispatch_rates(board_id) do
    %{rows: rows} = Repo.query!(@dispatch_rates_sql, [board_id])

    Map.new(rows, fn [name, total, dispatched] ->
      rate = if total > 0, do: dispatched / total * 100.0, else: 0.0
      {name, rate}
    end)
  end

  @doc """
  Returns a map of skip-reason string to count of skipped steps matching that
  reason across all tasks on the given board.

  Only steps where `"skipped"` is `true` are counted. Steps skipped without a
  reason are grouped under the empty string key.
  """
  def skip_reasons(board_id) do
    %{rows: rows} = Repo.query!(@skip_reasons_sql, [board_id])

    Map.new(rows, fn [reason, count] -> {reason, count} end)
  end

  @doc """
  Returns a map of agent name to compliance metrics across all tasks on the
  given board that have a `completed_by_agent` value.

  Each entry contains:

    * `:total_tasks` — number of tasks completed by that agent on the board
    * `:tasks_with_steps` — count of those tasks that have at least one workflow step
    * `:avg_steps` — average number of workflow steps per task (0.0 when no tasks)
  """
  def compliance_by_agent(board_id) do
    from(t in Task,
      join: c in assoc(t, :column),
      where: c.board_id == ^board_id,
      where: not is_nil(t.completed_by_agent),
      group_by: t.completed_by_agent,
      select: {
        t.completed_by_agent,
        %{
          total_tasks: count(t.id),
          tasks_with_steps:
            fragment("COUNT(*) FILTER (WHERE jsonb_array_length(?) > 0)", t.workflow_steps),
          avg_steps:
            fragment("COALESCE(AVG(jsonb_array_length(?))::float, 0.0)", t.workflow_steps)
        }
      }
    )
    |> Repo.all()
    |> Map.new()
  end
end
