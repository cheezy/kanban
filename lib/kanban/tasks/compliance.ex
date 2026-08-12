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
  # (D239) Buckets on `reason_code` when the entry carries one, falling back to
  # the verbatim `reason` prose when it does not.
  #
  # This is NOT the read-side canonicalisation D233 rejected. Nothing here maps
  # prose to a bucket — it reads a structured field that the write side
  # (`Kanban.Tasks.WorkflowSteps`) validates against a closed vocabulary. An
  # entry with no `reason_code` still groups by its exact text, so legacy rows
  # and novel skip reasons stay visible verbatim rather than being guessed at.
  #
  # NULLIF guards the empty string: a `reason_code` of "" must fall through to
  # the prose rather than collapsing every such row into one bucket.
  @skip_reasons_sql """
  SELECT COALESCE(NULLIF(elem->>'reason_code', ''), elem->>'reason', '') AS reason,
         COUNT(*) AS count
  FROM tasks t
  JOIN columns c ON c.id = t.column_id
  CROSS JOIN LATERAL jsonb_array_elements(t.workflow_steps) AS elem
  WHERE c.board_id = $1
    AND (elem->>'dispatched')::boolean IS FALSE
  GROUP BY COALESCE(NULLIF(elem->>'reason_code', ''), elem->>'reason', '')
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

  ## How the bucketing works, and why it is not read-side canonicalisation

  An entry that carries a `reason_code` is grouped by that code; an entry
  without one is grouped by its verbatim `reason` text. Both cases are still
  counted, so the total never moves.

  This was D233's open problem and D239 resolved it, but deliberately **not**
  by mapping prose to buckets here. D233 rejected that and the rejection still
  stands: any mapping written today would be fitted to the prose of the agents
  that happen to exist now, and would silently mis-file wording it did not
  anticipate — the failure the defect was itself an instance of. Measured at
  the time: 73 skipped entries on the production board produced 58 distinct
  reason strings averaging 145 characters, so grouping prose verbatim is very
  nearly one row per entry.

  What changed is the write side. `Kanban.Tasks.WorkflowSteps` now defines a
  six-value `reason_code` vocabulary — derived by classifying those 73 real
  entries rather than invented — and validates it on completion. This query
  reads that structured field. It guesses at nothing, so a novel skip reason
  with no code still appears verbatim instead of vanishing into an "other"
  bucket, and rows written before D239 keep grouping exactly as they did.

  `name` is deliberately **not** constrained; `Kanban.Tasks.WorkflowSteps`
  records that decision and the measured back-compat evidence behind it.
  `step_dispatch_rates/1` therefore still groups by whatever name was written,
  which keeps a misspelled or invented step visible as its own row.
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
