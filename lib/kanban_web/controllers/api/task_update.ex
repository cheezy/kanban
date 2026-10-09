defmodule KanbanWeb.API.TaskUpdate do
  @moduledoc """
  Task updates for `PATCH /api/tasks/:id`, split from
  `KanbanWeb.API.TaskController` to keep the controller under the module size
  guideline.

  `update/3` runs after the controller's live board-write check (D109) has
  passed. It fetches the task board-scoped, refuses a column move (403 —
  columns change only through the workflow endpoints), refuses any field this
  endpoint cannot change (D227, a 422 rather than a silent 200), and otherwise
  applies the update and renders the task. `labels` is resolved by
  `KanbanWeb.API.TaskLabels` before the update and applied after it (W2239). The mass-assignment audit log and
  telemetry fire on every path that filtered a forbidden field.

  Like `KanbanWeb.API.TaskErrors`, this module takes `conn` and renders; the
  statuses, bodies and telemetry events are exactly the ones the controller
  produced inline.
  """

  import Plug.Conn, only: [put_status: 2]
  import Phoenix.Controller, only: [json: 2, render: 3]

  alias Kanban.Tasks
  alias KanbanWeb.API.ErrorDocs
  alias KanbanWeb.API.TaskActions
  alias KanbanWeb.API.TaskErrors
  alias KanbanWeb.API.TaskLabels
  alias KanbanWeb.API.TaskParamFilter

  @doc """
  Updates the task named by `id_or_identifier` on the conn's board with
  `task_params`. The caller must already have authorized the board write.
  """
  def update(conn, id_or_identifier, task_params) do
    board = conn.assigns.current_board

    case TaskActions.fetch_task(id_or_identifier, board) do
      {:ok, task} ->
        if TaskParamFilter.column_change_attempted?(task_params, task) do
          reject_column_change(conn, task)
        else
          perform_api_task_update(conn, task, task_params)
        end

      error ->
        TaskErrors.handle_task_error(conn, error)
    end
  end

  defp reject_column_change(conn, task) do
    TaskActions.emit_telemetry(conn, :task_update_column_change_forbidden, %{task_id: task.id})

    TaskErrors.error_response(
      conn,
      :forbidden,
      "Agents cannot move tasks between columns via update. Use the workflow endpoints (claim, complete, mark_reviewed, mark_done) to transition tasks.",
      :column_change_forbidden
    )
  end

  defp perform_api_task_update(conn, task, task_params) do
    {safe_params, rejected_fields} = TaskParamFilter.filter_forbidden_update_fields(task_params)

    log_update_forbidden_fields(conn, task, rejected_fields)

    # `column_id` is excluded from the refusal. It is on the forbidden list, but
    # it already has its own upstream gate: `column_change_attempted?/2` returns
    # 403 for a substantive move, so anything reaching here is an idempotent
    # echo of the task's current column — which callers legitimately send and
    # which has always been allowed through. Failing it would break that, and
    # this defect is about silent discards, not about tightening column moves.
    refusable = rejected_fields -- ["column_id"]

    if refusable == [] do
      apply_api_task_update(conn, task, safe_params)
    else
      reject_forbidden_update(conn, refusable)
    end
  end

  # (D227) A PATCH naming a field this endpoint cannot change now FAILS rather
  # than returning 200 with the field quietly dropped.
  #
  # The fields are genuinely immutable here — they belong to the claim/complete/
  # mark_reviewed workflow endpoints, and that is deliberate. What was not
  # defensible was reporting success for a write that never happened: a caller
  # correcting a completion record got HTTP 200, a normal task body and no
  # errors key, so a record known to be wrong stayed wrong while its author
  # believed it was fixed. A 200 that changed nothing is indistinguishable from
  # a 200 that changed everything.
  #
  # The whole request is rejected rather than partially applied, including when
  # it mixes an editable field with an immutable one. Partial application would
  # reintroduce the same ambiguity one level down — the caller would still have
  # to diff the response to learn which half landed.
  #
  # The audit log and telemetry above still fire: this is now a visible refusal
  # AND a recorded one, not a swap of one for the other.
  defp reject_forbidden_update(conn, rejected_fields) do
    body =
      ErrorDocs.add_docs_to_error(
        %{
          error: "task update rejected",
          failures: [
            %{
              field: "task",
              errors:
                Enum.map(rejected_fields, fn field ->
                  %{field: field, message: TaskParamFilter.forbidden_update_message(field)}
                end)
            }
          ]
        },
        :update_forbidden_field
      )

    conn
    |> put_status(:unprocessable_entity)
    |> json(body)
  end

  # W2239: `labels` is popped before the changeset and resolved first, so an
  # unknown name is a 422 that changes nothing. Present, it replaces the set
  # (an empty list clears it); absent, the task's labels are left untouched.
  defp apply_api_task_update(conn, task, safe_params) do
    scope = TaskLabels.scope(conn)

    case pop_label_plan(conn, scope, safe_params) do
      {:ok, params, label_plan} ->
        update_task_and_labels(conn, scope, task, params, label_plan)

      {:error, message} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: TaskLabels.error_changeset([message]))
    end
  end

  defp pop_label_plan(conn, scope, params) do
    case Map.pop(params, "labels", :absent) do
      {:absent, params} ->
        {:ok, params, nil}

      {raw, params} ->
        with {:ok, ids} <- TaskLabels.resolve(scope, conn.assigns.current_board, raw) do
          {:ok, params, ids}
        end
    end
  end

  defp update_task_and_labels(conn, scope, task, params, label_plan) do
    case Tasks.api_update_task(task, params) do
      {:ok, updated_task} ->
        TaskLabels.apply_plan(scope, updated_task, label_plan)
        updated_task = Tasks.get_task_for_view!(updated_task.id)
        TaskActions.emit_telemetry(conn, :task_updated, %{task_id: updated_task.id})
        render(conn, :show, task: updated_task)

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
    end
  end

  # Emits the update-path mass-assignment audit log (via TaskParamFilter) and,
  # when a forbidden field was rejected, the companion telemetry event.
  defp log_update_forbidden_fields(conn, task, rejected_fields) do
    TaskParamFilter.log_update_mass_assignment(
      task.id,
      rejected_fields,
      TaskParamFilter.actor_user_id(conn)
    )

    if rejected_fields != [] do
      TaskActions.emit_telemetry(conn, :task_update_forbidden_fields_filtered, %{
        task_id: task.id,
        fields: rejected_fields
      })
    end
  end
end
