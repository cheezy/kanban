defmodule KanbanWeb.API.TaskJSON do
  alias Kanban.Tasks.Task
  alias KanbanWeb.API.ErrorDocs

  @doc """
  Task list view. Under `response_view=slim` (W2057) each row is the canonical
  compact summary instead of the full `data/1` render — a board-wide list of fat
  task objects is the largest response this API produces, and almost none of it
  is read when the caller is listing rather than reading.

  Clause order is load-bearing, for the same reason spelled out for `ack/1`
  below: `render/3` merges `conn.assigns`, so the assigns map always carries
  `conn`, `current_board` and friends, and the bare clause would match a
  `:slim`-carrying map just as happily. The slim clause must therefore come
  first. The bare clause is the fallthrough rather than an explicit `:full`
  match, mirroring `TaskController.view_for/1`: anything unrecognised resolves
  to full, because a fat response is a better failure than a crash.
  """
  def index(%{tasks: tasks, response_view: :slim}) do
    %{data: Enum.map(tasks, &render_task_summary/1)}
  end

  def index(%{tasks: tasks}) do
    %{data: for(task <- tasks, do: data(task))}
  end

  @doc """
  Single-task view.

  Under a `fields` projection (W2076) the task renders as `id` and
  `identifier` plus exactly the requested allow-listed fields — the
  controller only ever threads a `fields` assign that
  `KanbanWeb.API.TaskFieldsProjection.resolve/1` validated, and never
  alongside `response_view` (the two parameters are mutually exclusive at
  the controller boundary).

  Under `response_view=slim` (W2074) the task renders as the same canonical
  compact summary the index and tree endpoints serve, because the full
  render — `review_report` included — is tens of KB and the single most
  expensive artifact a dispatcher session reads.

  Clause order is load-bearing for the same reason spelled out on `index/1`:
  the bare `%{task: task}` clause would match a `fields`- or
  `:slim`-carrying assigns map just as happily, so those clauses must come
  first. The `hook`/`hooks` clauses serve claim/complete responses, which
  never thread `response_view` or `fields`.
  """
  def show(%{task: task, fields: fields}) when is_list(fields) do
    %{data: task |> projectable_data() |> Map.take(fields)}
  end

  def show(%{task: task, response_view: :slim}) do
    %{data: render_task_summary(task)}
  end

  def show(%{task: task, hook: hook} = assigns) do
    %{data: data(task), hook: hook}
    |> maybe_add_skills_version(assigns)
  end

  def show(%{task: task, hooks: hooks} = assigns) do
    %{data: data(task), hooks: hooks}
    |> maybe_add_skills_version(assigns)
  end

  def show(%{task: task} = assigns) do
    %{data: data(task)}
    |> maybe_add_skills_version(assigns)
  end

  @doc """
  Task tree view. Under `response_view=slim` (W2057) the children render as
  compact summaries, but the root `task` keeps its full render in both views and
  `counts` is passed through untouched.

  That asymmetry is deliberate, and is the thing most likely to be "harmonised"
  away by a later reader: `/dependencies` and `/dependents` render the summary
  shape for their subject task as well as for their list — unconditionally, with
  no view gate at all — but `/tree` is the one response where the caller reads
  the goal's own planning fields — `why`, `what`, `acceptance_criteria`,
  `key_files` — alongside its children. The caller asked for that specific task
  and needs its detail; the children are navigational. Slimming the root would
  take away the detail the request was made for.

  Clause order is load-bearing here for the same reason as `index/1` above.
  """
  def tree(%{tree: tree, response_view: :slim}) do
    %{
      data: %{
        task: data(tree.task),
        children: Enum.map(tree.children, &render_task_summary/1),
        counts: tree.counts
      }
    }
  end

  def tree(%{tree: tree}) do
    %{
      data: %{
        task: data(tree.task),
        children: Enum.map(tree.children, &data/1),
        counts: tree.counts
      }
    }
  end

  @doc """
  Compact after_goal status view. Deliberately minimal — no `reviewer_result`
  or other large fields — so the response is never subject to output truncation.
  """
  def after_goal_status(%{goal: nil}) do
    %{after_goal_armed: false, goal_id: nil, goal_identifier: nil, env: %{}}
  end

  def after_goal_status(%{goal: %Task{} = goal, board: board}) do
    %{
      after_goal_armed: true,
      goal_id: goal.id,
      goal_identifier: goal.identifier,
      env: after_goal_env(goal, board)
    }
  end

  @doc """
  Acknowledgement view for `PUT /api/tasks/:id/changed_files`, selected only by
  an explicit `response_view=slim`.

  Deliberately minimal, for the same reason as `after_goal_status/1`: the whole
  point of that endpoint is to *receive* a diff, and the default `show/1` view
  echoes the very same diff straight back — up to 500 lines per file — into the
  caller's context, where an agent then re-sends it on every later request.
  Nothing reads the echo, so the slim view acknowledges the write with the
  task's identity and status fields and omits `changed_files` entirely.

  This changes only the echo, never the storage: the field is still persisted,
  and `GET /api/tasks/:id` still serves it in full.

  W2059 reuses this same view for `PATCH /api/tasks/:id/complete`, where the
  echoed payload (`reviewer_result` with its 25 `project_checks`, plus
  `explorer_result`, `review_report` and `workflow_steps`) is large enough to
  push the response past the harness truncation threshold — cutting the JSON
  mid-string so `after_goal` detection silently fails and the goal-completion
  push never fires. That is the root cause `D118` and `D119` work around.

  The `hooks`-bearing clause below exists because that endpoint MUST keep its
  envelope: `stride-hook.sh` reads `.hooks[].name`, `.hooks[].env` and, as the
  `GOAL_ID` fallback, `.data.parent_id`. Rendering the bare clause there would
  match (Elixir map patterns match subsets) and silently drop `hooks` and the
  skills-version keys — reintroducing the exact silent failure this change
  removes. The bare clause is deliberately left envelope-free for the
  changed_files endpoint, which passes no `hooks` and no `skills_version`.
  """
  def ack(%{task: %Task{} = task, hook: hook} = assigns) do
    %{data: ack_data(task), hook: hook}
    |> maybe_add_skills_version(assigns)
  end

  def ack(%{task: %Task{} = task, hooks: hooks} = assigns) do
    %{data: ack_data(task), hooks: hooks}
    |> maybe_add_skills_version(assigns)
  end

  def ack(%{task: %Task{} = task}) do
    %{data: ack_data(task)}
  end

  @doc """
  Back-compatible alias for `ack/1`, kept because the view was introduced under
  this name by W2056 and is still referenced by name in its tests.
  """
  def changed_files_ack(assigns), do: ack(assigns)

  @doc """
  Canonical compact summary shape for a single task.

  Three responses render it byte-for-byte — `GET /api/tasks/:id/dependencies`
  (both the subject task and every node of the dependency tree), `GET
  /api/tasks/:id/dependents`, and the `child_tasks` entries of goal creation
  (single `POST /api/tasks` and `POST /api/tasks/batch`) — so widening it
  widens all of them at once. It is deliberately narrower than `data/1`:
  anything added here is exposed on endpoints that were only ever meant to
  return a compact row.

  Unlike the other public functions in this module it is **not** a Phoenix
  template: it takes a task, not an assigns map, and is called directly rather
  than through `render/3`. `KanbanWeb.API.TaskController.render_task_summary/1`
  delegates here so that `KanbanWeb.API.BatchGoalCreation`, which calls it by
  that name, keeps resolving unchanged.

  (W2092) `type`, `parent_id`, and `claim_expires_at` are deliberate additions:
  they are the workflow-critical state the 11-step agent loop reads (goal
  detection, goal completion, claim-expiry monitoring) that agents previously
  could not get from any summary row. `needs_review` and `review_status` are
  just as deliberately **omitted**: the W2058 review-field presence guard keeps
  every review-scoped field out of the summary shape, and the sanctioned path
  for those two is the `fields=` projection (both are allow-listed below —
  `fields=status,needs_review` is the documented review-gate read), or a full
  fetch on a server predating W2076.
  """
  def render_task_summary(task) do
    %{
      id: task.id,
      identifier: task.identifier,
      title: task.title,
      type: task.type,
      status: task.status,
      priority: task.priority,
      complexity: task.complexity,
      dependencies: task.dependencies || [],
      created_by_agent: task.created_by_agent,
      parent_id: task.parent_id,
      claim_expires_at: task.claim_expires_at
    }
  end

  @projectable_field_names ~w(id identifier title type status priority complexity
                              dependencies created_by_agent parent_id
                              claim_expires_at needs_review
                              review_status review_notes review_report
                              workflow_steps explorer_result reviewer_result
                              reviewed_at reviewed_by_id completed_at
                              completed_by_id completed_by_agent
                              completion_summary completion_notes
                              actual_complexity actual_files_changed)

  @doc """
  The `fields` projection allow-list (W2076): the single source of truth
  `KanbanWeb.API.TaskFieldsProjection.resolve/1` validates against.

  A deliberate literal, never derived from the Task schema — deriving it
  would silently expose future fields, and this list is the security
  boundary for the projection: only names already served by the full show
  response may appear here.
  """
  def projectable_field_names, do: @projectable_field_names

  # The renderer behind the fields projection: a string-keyed map covering
  # exactly @projectable_field_names, each value the same expression data/1
  # uses — except dependencies, which takes render_task_summary/1's
  # `|| []` normalisation so the summary-8 subset of a projection stays
  # byte-identical to response_view=slim. Like data/1 above, it is one flat
  # literal map — ABC size counts its 27 field reads, but there is no logic
  # to extract.
  # credo:disable-for-next-line Credo.Check.Refactor.ABCSize
  defp projectable_data(%Task{} = task) do
    %{
      "id" => task.id,
      "identifier" => task.identifier,
      "title" => task.title,
      "type" => task.type,
      "status" => task.status,
      "priority" => task.priority,
      "complexity" => task.complexity,
      "dependencies" => task.dependencies || [],
      "created_by_agent" => task.created_by_agent,
      "parent_id" => task.parent_id,
      "claim_expires_at" => task.claim_expires_at,
      "needs_review" => task.needs_review,
      "review_status" => task.review_status,
      "review_notes" => task.review_notes,
      "review_report" => task.review_report,
      "workflow_steps" => task.workflow_steps,
      "explorer_result" => task.explorer_result,
      "reviewer_result" => task.reviewer_result,
      "reviewed_at" => task.reviewed_at,
      "reviewed_by_id" => task.reviewed_by_id,
      "completed_at" => task.completed_at,
      "completed_by_id" => task.completed_by_id,
      "completed_by_agent" => task.completed_by_agent,
      "completion_summary" => task.completion_summary,
      "completion_notes" => task.completion_notes,
      "actual_complexity" => task.actual_complexity,
      "actual_files_changed" => task.actual_files_changed
    }
  end

  defp ack_data(%Task{} = task) do
    %{
      id: task.id,
      identifier: task.identifier,
      title: task.title,
      status: task.status,
      parent_id: task.parent_id,
      needs_review: task.needs_review,
      review_status: task.review_status,
      complexity: task.complexity,
      priority: task.priority
    }
  end

  # The GOAL_* env block the after_goal hook exports (mirrors the keys the
  # plugin's export_after_goal_env reads: GOAL_ID/GOAL_IDENTIFIER/GOAL_TITLE/
  # GOAL_DESCRIPTION), plus BOARD_* and HOOK_NAME. Values are strings — the hook
  # sources them into a shell env.
  defp after_goal_env(goal, board) do
    %{
      "GOAL_ID" => to_string(goal.id),
      "GOAL_IDENTIFIER" => goal.identifier || "",
      "GOAL_TITLE" => goal.title || "",
      "GOAL_DESCRIPTION" => goal.description || "",
      "BOARD_ID" => to_string(board.id),
      "BOARD_NAME" => board.name,
      "HOOK_NAME" => "after_goal"
    }
  end

  # credo:disable-for-next-line Credo.Check.Refactor.ABCSize
  defp data(%Task{} = task) do
    %{
      id: task.id,
      title: task.title,
      description: task.description,
      acceptance_criteria: task.acceptance_criteria,
      position: task.position,
      type: task.type,
      priority: task.priority,
      identifier: task.identifier,
      column_id: task.column_id,
      assigned_to_id: task.assigned_to_id,
      parent_id: task.parent_id,
      complexity: task.complexity,
      estimated_files: task.estimated_files,
      why: task.why,
      what: task.what,
      where_context: task.where_context,
      patterns_to_follow: task.patterns_to_follow,
      database_changes: task.database_changes,
      validation_rules: task.validation_rules,
      telemetry_event: task.telemetry_event,
      metrics_to_track: task.metrics_to_track,
      logging_requirements: task.logging_requirements,
      error_user_message: task.error_user_message,
      error_on_failure: task.error_on_failure,
      key_files: render_key_files(task),
      verification_steps: render_verification_steps(task),
      behaviour_test_matrix: render_behaviour_test_matrix(task),
      technology_requirements: task.technology_requirements,
      pitfalls: task.pitfalls,
      out_of_scope: task.out_of_scope,
      security_considerations: task.security_considerations,
      testing_strategy: task.testing_strategy,
      integration_points: task.integration_points,
      technical_details: task.technical_details,
      created_by_id: task.created_by_id,
      created_by_agent: task.created_by_agent,
      completed_at: task.completed_at,
      completed_by_id: task.completed_by_id,
      completed_by_agent: task.completed_by_agent,
      completion_summary: task.completion_summary,
      completion_notes: task.completion_notes,
      dependencies: task.dependencies,
      status: task.status,
      claimed_at: task.claimed_at,
      claim_expires_at: task.claim_expires_at,
      required_capabilities: task.required_capabilities,
      actual_complexity: task.actual_complexity,
      actual_files_changed: task.actual_files_changed,
      changed_files: task.changed_files,
      time_spent_minutes: task.time_spent_minutes,
      human_task: task.human_task,
      needs_review: task.needs_review,
      review_status: task.review_status,
      review_notes: task.review_notes,
      review_report: task.review_report,
      workflow_steps: task.workflow_steps,
      explorer_result: task.explorer_result,
      reviewer_result: task.reviewer_result,
      reviewed_at: task.reviewed_at,
      reviewed_by_id: task.reviewed_by_id,
      inserted_at: task.inserted_at,
      updated_at: task.updated_at
    }
  end

  defp render_key_files(%Task{key_files: key_files}) when is_list(key_files) do
    Enum.map(key_files, fn kf ->
      %{
        file_path: kf.file_path,
        note: kf.note,
        position: kf.position
      }
    end)
  end

  defp render_key_files(_), do: []

  defp render_verification_steps(%Task{verification_steps: steps}) when is_list(steps) do
    Enum.map(steps, fn step ->
      %{
        step_type: step.step_type,
        step_text: step.step_text,
        expected_result: step.expected_result,
        position: step.position
      }
    end)
  end

  defp render_verification_steps(_), do: []

  defp render_behaviour_test_matrix(%Task{behaviour_test_matrix: rows}) when is_list(rows) do
    Enum.map(rows, fn row ->
      %{
        category: row.category,
        behaviour: row.behaviour,
        test_name: row.test_name,
        type: row.type,
        status: row.status,
        na_reason: row.na_reason,
        position: row.position
      }
    end)
  end

  defp render_behaviour_test_matrix(_), do: []

  defp maybe_add_skills_version(response, assigns) do
    current = KanbanWeb.API.AgentJSON.skills_version()
    response = Map.put(response, :current_skills_version, current)

    case assigns[:agent_skills_version] do
      nil ->
        response

      "" ->
        response

      version when version == current ->
        response

      stale_version ->
        Map.put(response, :skills_update_required, %{
          current_version: current,
          your_version: stale_version,
          action: "Run /plugin update stride to get the latest skills",
          reason: "Your local skills are outdated."
        })
    end
  end

  def error(%{changeset: changeset}) do
    errors = Ecto.Changeset.traverse_errors(changeset, &translate_changeset_error/1)

    # Add documentation links for fields with errors
    documentation = ErrorDocs.get_docs(:validation_error, fields: Map.keys(errors))

    %{
      errors: errors,
      documentation: documentation
    }
  end

  defp translate_changeset_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", stringify_error_value(value))
    end)
  end

  defp stringify_error_value(value) when is_binary(value) or is_number(value) or is_atom(value),
    do: to_string(value)

  defp stringify_error_value(value), do: inspect(value)
end
