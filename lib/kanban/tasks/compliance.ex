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

  # (D233) Filters on `dispatched` being FALSE, not on a `skipped` key.
  #
  # The workflow_steps schema has no `skipped` key. A skipped step is recorded
  # as `dispatched: false` with a `reason` — that is what the documented schema
  # says, what `AgentWorkflow.validate_workflow_steps_shape/2` enforces, and
  # what every emitting agent writes. Filtering on `skipped` therefore matched
  # nothing in real data, so this panel was silently empty rather than visibly
  # wrong. Confirmed against production: sampled task payloads carry only
  # `dispatched` + `duration_ms` or `dispatched` + `reason`, and no `skipped`
  # key at all.
  #
  # A missing `dispatched` key yields NULL, and `NULL IS FALSE` is false, so
  # entries that predate the field are not counted rather than miscounted.
  @skip_reasons_sql """
  SELECT COALESCE(elem->>'reason', '') AS reason,
         COUNT(*) AS count
  FROM tasks t
  JOIN columns c ON c.id = t.column_id
  CROSS JOIN LATERAL jsonb_array_elements(t.workflow_steps) AS elem
  WHERE c.board_id = $1
    AND (elem->>'dispatched')::boolean IS FALSE
  GROUP BY COALESCE(elem->>'reason', '')
  """

  @doc """
  Returns a map of step name to dispatch metrics across all tasks on the given
  board.

  Each entry contains:

    * `:rate` — dispatch percentage (0.0 to 100.0)
    * `:total` — total number of times this step appears
    * `:dispatched` — number of times the step was dispatched

  A step is considered "dispatched" when its `"dispatched"` key is `true`.
  Steps with no `"name"` key are ignored. Tasks with an empty `workflow_steps`
  array contribute nothing.
  """
  def step_dispatch_rates(board_id) do
    %{rows: rows} = Repo.query!(@dispatch_rates_sql, [board_id])

    Map.new(rows, fn [name, total, dispatched] ->
      rate = if total > 0, do: dispatched / total * 100.0, else: 0.0
      {name, %{rate: rate, total: total, dispatched: dispatched}}
    end)
  end

  @doc """
  Returns a map of skip-reason string to count of skipped steps matching that
  reason across all tasks on the given board.

  A step counts as skipped when `"dispatched"` is `false` — the schema has no
  `"skipped"` key (D233). Steps skipped without a reason are grouped under the
  empty string key; historical rows predate the validator that now requires a
  reason, so that bucket is not dead code.

  ## On reason text, decided deliberately rather than by omission (D233)

  Reasons are **not** canonicalised here, and that is a decision with a cost.
  Unlike `explorer_result.reason` and `reviewer_result.reason` — which
  `Kanban.Tasks.CompletionValidation` constrains to a five-value enum — a
  `workflow_steps` reason is only required to be a string, so agents write free
  prose. Measured against real completions: 12 skipped entries produced 10
  distinct strings averaging 145 characters, so grouping verbatim yields very
  nearly one row per entry.

  Bucketing was rejected rather than overlooked. Any mapping written today
  would be fitted to the prose of the agents that happen to exist now, and
  would silently mis-file wording it did not anticipate — the failure this
  defect is already an instance of. Keeping the text raw means a novel skip
  reason stays visible verbatim instead of vanishing into an "other" bucket.

  The real fix is to constrain the vocabulary where it is written, mirroring
  the existing enum for explorer/reviewer reasons, which is a change to the
  emitting contract rather than to this query. **Filed as D239**, which also
  covers constraining `name` to the canonical step list — persisted data already
  contains two different step vocabularies from two runtimes, so that change
  carries the same back-compat hazard and belongs with this one.
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
