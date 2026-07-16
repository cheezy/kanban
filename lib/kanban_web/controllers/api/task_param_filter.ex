defmodule KanbanWeb.API.TaskParamFilter do
  @moduledoc """
  Mass-assignment protection for the task API.

  Extracted from `KanbanWeb.API.TaskController` (W1443). Strips server-controlled
  and workflow-only fields that an API client may not set directly on create or
  update, detects forbidden cross-column moves, and emits the monitored
  mass-assignment audit log lines. These are security controls — the forbidden
  field lists, the column-change fail-closed detection, and the audit log
  message strings must stay byte-identical.

  The functions are conn-free: filters are pure `params -> {safe, rejected}`
  transforms, `column_change_attempted?/2` is a pure predicate, and the
  `log_*_mass_assignment` functions take primitive actor/field values so the
  controller keeps its own telemetry emission and error rendering.
  """

  require Logger

  # String keys an API client may NOT mass-assign on POST /api/tasks (or
  # /api/tasks/batch). status defaults to :open via the schema, identifier and
  # position are generated server-side, and the workflow/audit fields can only
  # be set by the dedicated workflow endpoints. created_by_id and
  # created_by_agent are not in this list because the controller helper
  # `build_task_params_with_creator/4` overwrites them server-side after the
  # filter — they need to flow through the changeset's allow-list.
  #
  # parent_id is forbidden here even though the changeset casts it: the ONLY
  # legitimate parent link is the goal id the server injects into child attrs
  # during batch goal creation (Creation.prepare_child_task_attrs/5). A
  # client-supplied parent_id would otherwise link the new task under a goal on
  # another board (cross-board IDOR) and, via assignment inheritance, copy that
  # goal's assigned_to_id — an indirect write of the forbidden assigned_to_id
  # field (D153).
  @forbidden_api_create_fields ~w(
    status
    identifier
    position
    claimed_at
    claim_expires_at
    completed_at
    completed_by_id
    completed_by_agent
    completion_summary
    actual_complexity
    actual_files_changed
    time_spent_minutes
    review_status
    review_notes
    review_report
    reviewed_by_id
    reviewed_at
    workflow_steps
    explorer_result
    reviewer_result
    archived_at
    assigned_to_id
    parent_id
  )

  # String keys (since params arrive from JSON as strings) that an API client
  # may NOT mass-assign via PATCH /api/tasks/:id. These flow through the
  # dedicated workflow endpoints (claim/complete/mark_reviewed) instead.
  # Defense in depth: the controller filters and logs; Task.api_update_changeset/2
  # also enforces the allow-list at the changeset layer.
  @forbidden_api_update_fields ~w(
    status
    identifier
    parent_id
    column_id
    position
    assigned_to_id
    claimed_at
    claim_expires_at
    completed_at
    completed_by_id
    completed_by_agent
    completion_summary
    actual_complexity
    actual_files_changed
    time_spent_minutes
    review_status
    review_notes
    review_report
    reviewed_by_id
    reviewed_at
    workflow_steps
    explorer_result
    reviewer_result
    created_by_id
    created_by_agent
    archived_at
  )

  @doc """
  True when `task_params` attempts to move the task to a different column (or
  carries an unparseable `column_id`, which is treated as an attempt — fail
  closed). Column moves must go through the workflow endpoints.
  """
  def column_change_attempted?(%{"column_id" => new_id}, task) do
    case parse_id(new_id) do
      {:ok, int_id} -> int_id != task.column_id
      :error -> true
    end
  end

  def column_change_attempted?(_task_params, _task), do: false

  @doc """
  Splits `task_params` into the safe subset (allowed fields only) and the list
  of forbidden update-field names that were present in the original payload.
  Always also strips `column_id` (column moves happen via the workflow
  endpoints, and the upstream `column_change_attempted?/2` check has already
  produced 403 for substantive column changes).
  """
  def filter_forbidden_update_fields(task_params) do
    rejected = Enum.filter(@forbidden_api_update_fields, &Map.has_key?(task_params, &1))
    safe_params = Map.drop(task_params, @forbidden_api_update_fields)
    {safe_params, rejected}
  end

  @doc """
  Strips the create-path forbidden fields and returns `{safe_params, rejected}`.
  Unlike the update filter, this keeps `column_id` (the create flow legitimately
  honors it after `verify_column_ownership`). Non-map input passes through.
  """
  def filter_forbidden_create_fields(task_params) when is_map(task_params) do
    rejected = Enum.filter(@forbidden_api_create_fields, &Map.has_key?(task_params, &1))
    safe_params = Map.drop(task_params, @forbidden_api_create_fields)
    {safe_params, rejected}
  end

  def filter_forbidden_create_fields(other), do: {other, []}

  @doc """
  Filters a list of child task maps (from `POST /api/tasks` with `tasks: [...]`
  or `POST /api/tasks/batch`). Returns the cleaned list plus a deduplicated list
  of any forbidden field names that appeared across children.
  """
  def filter_child_tasks(child_tasks) when is_list(child_tasks) do
    {safe_children, rejected_lists} =
      Enum.map_reduce(child_tasks, [], fn child, acc ->
        {safe, rejected} = filter_forbidden_create_fields(child)
        {safe, acc ++ rejected}
      end)

    {safe_children, Enum.uniq(rejected_lists)}
  end

  def filter_child_tasks(other), do: {other, []}

  @doc """
  Emits the monitored update-path mass-assignment audit log line. No-op when no
  forbidden field was rejected. The controller emits the companion telemetry
  event separately.
  """
  def log_update_mass_assignment(_task_id, [], _actor_user_id), do: :ok

  def log_update_mass_assignment(task_id, rejected_fields, actor_user_id) do
    Logger.info("API mass-assignment attempt rejected",
      task_id: task_id,
      rejected_fields: rejected_fields,
      actor_user_id: actor_user_id
    )
  end

  @doc """
  Emits the monitored create-path mass-assignment audit log line. No-op when no
  forbidden field was rejected on the goal or any child. The controller emits
  the companion telemetry event separately.
  """
  def log_create_mass_assignment([], [], _actor_user_id), do: :ok

  def log_create_mass_assignment(goal_fields, child_fields, actor_user_id) do
    Logger.info("API mass-assignment attempt rejected on create",
      rejected_fields: Enum.uniq(goal_fields ++ child_fields),
      actor_user_id: actor_user_id
    )
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> {:ok, int_id}
      _ -> :error
    end
  end

  defp parse_id(_), do: :error
end
