defmodule KanbanWeb.TaskLive.Form.Save do
  @moduledoc """
  The task form's save path, kept out of `KanbanWeb.TaskLive.FormComponent`
  so the component stays under the module-size guideline in `AGENTS.md`.

  `save/2` is the component's `"save"` event. In order it:

    1. checks modify access on the board (D110), so a read-only member or a
       non-member cannot persist a create or edit by pushing the event;
    2. normalises the telemetry fields (`TelemetryLock`) and decodes
       `technical_details`;
    3. resolves the label ids against the labels the picker offered
       (`LabelSelection`);
    4. checks every relational field against the board (`RelationalScopes`)
       and, for a new task, that the column is on the board;
    5. creates the task (refusing at a WIP limit) or updates it, with the
       identifier, review attribution and completion time set by the server;
    6. writes the labels, stores staged attachments for a new task
       (`AttachmentStaging`), tells the board, flashes and patches back.

  Every result is `{:noreply, socket}` for the component to return. A refusal
  re-renders the form with a changeset error and `:error_message`.
  """
  use Gettext, backend: KanbanWeb.Gettext

  import Phoenix.Component, only: [assign: 3, to_form: 1]
  import Phoenix.LiveView, only: [push_patch: 2, put_flash: 3]

  alias Kanban.Columns
  alias Kanban.Tasks
  alias KanbanWeb.TaskLive.Form.AttachmentStaging
  alias KanbanWeb.TaskLive.Form.LabelSelection
  alias KanbanWeb.TaskLive.Form.ParamNormalizer
  alias KanbanWeb.TaskLive.Form.RelationalScopes
  alias KanbanWeb.TaskLive.Form.TaskParams
  alias KanbanWeb.TaskLive.Form.TechnicalDetails
  alias KanbanWeb.TaskLive.Form.TelemetryLock
  alias KanbanWeb.TaskLive.FormComponent

  @doc """
  Saves the form's `task_params` as a new task or an edit of the form's task,
  once the user's modify access to the board is confirmed.
  """
  @spec save(Phoenix.LiveView.Socket.t(), map()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def save(socket, task_params) do
    if modify_authorized?(socket) do
      do_save_task(socket, task_params)
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext("You do not have permission to modify tasks on this board")
       )}
    end
  end

  # Runs the actual create/edit once modify access has been authorized in the
  # "save" handle_event (D110).
  defp do_save_task(socket, task_params) do
    {task_params, socket} = TelemetryLock.normalize_params(socket, task_params)
    raw = Map.get(task_params, "technical_details")

    case TechnicalDetails.decode(task_params) do
      {:ok, decoded_params} ->
        save_task_and_labels(socket, decoded_params)

      {:error, _raw} ->
        changeset =
          socket.assigns.task
          |> Tasks.Task.changeset(Map.delete(task_params, "technical_details"))
          |> Ecto.Changeset.add_error(:technical_details, "must be a JSON object")
          |> Map.put(:action, :validate)

        {:noreply,
         socket
         |> assign(:error_message, gettext("Please fix the errors below"))
         |> maybe_assign_technical_details_raw(raw)
         |> assign_form(changeset)}
    end
  end

  # Label ids are not a task field: resolve them within this board first (an
  # id the picker never offered rejects the save), then save the task and
  # write the labels once it exists. See KanbanWeb.TaskLive.Form.LabelSelection.
  defp save_task_and_labels(socket, params) do
    offered = Enum.map(socket.assigns.label_options, & &1.id)

    case LabelSelection.pop(params, offered, socket.assigns.initial_label_ids) do
      {:invalid, params} ->
        reject_with_scope_error(socket, params, :label_ids)

      {change, params} ->
        socket |> assign(:label_change, change) |> save_task(socket.assigns.action, params)
    end
  end

  defp save_task(socket, :edit_task, task_params) do
    task_params = ParamNormalizer.preserve_stored_values(task_params, socket.assigns.task)

    # Security: every relational field that the user can change via the
    # form must be verified to live on the current board. The existing
    # column_id check is preserved; parent_id and assigned_to_id are now
    # validated the same way. Each check is independent — a single bad
    # field rejects the whole save with a targeted changeset error.
    case RelationalScopes.validate(task_params, socket.assigns.board, socket.assigns.task) do
      :ok ->
        perform_task_update(socket, task_params)

      {:error, field, message} ->
        reject_with_scope_error(socket, task_params, field, message)
    end
  end

  # Security: the column must be on the current board. A column_id that is not
  # a number, or names no column, is refused the same way instead of raising.
  defp save_task(socket, :new_task, task_params) do
    case new_task_column(socket, task_params) do
      %{} = column ->
        # The changeset casts column_id, so a blank one would null the column out.
        create_scoped_task(socket, column, Map.put(task_params, "column_id", column.id))

      nil ->
        message = gettext("Column does not belong to this board")
        reject_with_scope_error(socket, task_params, :column_id, message)
    end
  end

  # The submitted column, or the one the form opened on when none is given;
  # nil unless it is a column on the current board.
  defp new_task_column(socket, task_params) do
    column_id = blank_to_nil(task_params["column_id"]) || socket.assigns.column_id

    case TaskParams.coerce_id(column_id) do
      {:ok, id} -> Columns.get_column_for_board(id, socket.assigns.board.id)
      :error -> nil
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # The same relational checks as an edit: a crafted save must not parent the
  # new task under another board's goal or assign a non-member.
  defp create_scoped_task(socket, column, task_params) do
    case RelationalScopes.validate(task_params, socket.assigns.board, socket.assigns.task) do
      :ok -> create_task_in_column(socket, column, task_params)
      {:error, field, message} -> reject_with_scope_error(socket, task_params, field, message)
    end
  end

  defp reject_with_scope_error(socket, task_params, field, message \\ nil) do
    changeset = Tasks.Task.changeset(socket.assigns.task, task_params)

    changeset =
      if message, do: Ecto.Changeset.add_error(changeset, field, message), else: changeset

    {:noreply,
     socket
     |> assign(:error_message, TaskParams.scope_error_label(field))
     |> assign_form(changeset)}
  end

  defp perform_task_update(socket, task_params) do
    task_params = prepare_task_update_params(socket, task_params)
    cascade_count = TaskParams.compute_cascade_count(socket.assigns.task, task_params)

    case save_task_update(socket, task_params) do
      {:ok, task} ->
        finish_task_update(socket, task, cascade_count)

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:error_message, gettext("Please fix the errors below"))
         |> assign_form(changeset)}
    end
  end

  defp finish_task_update(socket, task, cascade_count) do
    socket = LabelSelection.apply_change(socket, task)
    notify_parent({:saved, task})

    {:noreply,
     socket
     |> put_flash(:info, TaskParams.build_update_flash(cascade_count))
     |> push_patch(to: socket.assigns.patch)}
  end

  # Passing the acting user lets Tasks.update_task/3 skip the task_assigned
  # notification when someone assigns a task to themselves.
  defp save_task_update(socket, task_params) do
    Tasks.update_task(socket.assigns.task, task_params, actor: current_user(socket))
  end

  defp current_user(socket) do
    case Map.get(socket.assigns, :current_scope) do
      %{user: user} -> user
      _ -> nil
    end
  end

  # The identifier is server-owned: the form has no input for it, and a crafted
  # save carrying another task's identifier would give two tasks one
  # identifier, which no database index prevents (D354).
  defp prepare_task_update_params(socket, task_params) do
    task_params = Map.drop(task_params, ["identifier", :identifier])

    task_params =
      case Map.get(socket.assigns, :current_scope) do
        %{user: user} -> maybe_add_review_metadata(task_params, user)
        _ -> task_params
      end

    maybe_add_completed_at(task_params, socket.assigns.task)
  end

  defp create_task_in_column(socket, column, task_params) do
    case Tasks.create_task(column, task_params) do
      {:ok, task} ->
        handle_task_created(socket, task)

      {:error, :wip_limit_reached} ->
        handle_wip_limit_reached(socket, task_params)

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:error_message, gettext("Please fix the errors below"))
         |> assign_form(changeset)}
    end
  end

  defp handle_task_created(socket, task) do
    socket = LabelSelection.apply_change(socket, task)
    {socket, failed} = AttachmentStaging.store_staged(socket, socket.assigns.current_scope, task)
    notify_parent({:saved, task})

    {:noreply,
     socket
     |> put_flash(:info, gettext("Task created successfully"))
     |> AttachmentStaging.put_failure_flash(failed)
     |> push_patch(to: socket.assigns.patch)}
  end

  defp handle_wip_limit_reached(socket, task_params) do
    changeset =
      socket.assigns.task
      |> Tasks.Task.changeset(task_params)
      |> Ecto.Changeset.add_error(:column_id, gettext("WIP limit reached for this column"))

    {:noreply,
     socket
     |> assign(:error_message, gettext("Cannot add task: WIP limit reached for this column"))
     |> assign_form(changeset)}
  end

  # W403: review attribution and completion timestamps are server-owned audit
  # fields. The previous Map.put_new / Map.has_key? pattern let a board member
  # forge them via a crafted form payload (CWE-639). Now we ALWAYS overwrite
  # those keys with server values when the status transition fires, and we
  # drop any client-supplied version up front so even non-transition saves do
  # not let a malicious client persist forged values. Exposed via @doc false so
  # the regression tests in form_component_test.exs can exercise the logic
  # directly without the full LiveView submit roundtrip.
  @doc false
  def maybe_add_review_metadata(task_params, current_user) do
    # Strip any client-supplied review attribution unconditionally — the server
    # is the only authority for who reviewed and when.
    task_params = Map.drop(task_params, ["reviewed_at", "reviewed_by_id"])
    review_status = task_params["review_status"]

    if review_status && review_status != "" && review_status != "pending" do
      task_params
      |> Map.put("reviewed_at", DateTime.utc_now() |> DateTime.truncate(:second))
      |> Map.put("reviewed_by_id", current_user.id)
    else
      task_params
    end
  end

  @doc false
  def maybe_add_completed_at(task_params, task) do
    # Strip any client-supplied completion timestamp unconditionally — the
    # server's `DateTime.utc_now/0` is the only authority. Cycle-time metrics
    # depend on this being honest.
    task_params = Map.drop(task_params, ["completed_at"])
    status = task_params["status"]

    if (status == "completed" || status == :completed) && is_nil(task.completed_at) do
      Map.put(task_params, "completed_at", DateTime.utc_now() |> DateTime.truncate(:second))
    else
      task_params
    end
  end

  # D110: the task create/edit save path is a modify action. Board access is
  # verified authoritatively here (current_scope + board -> Boards.can_modify?)
  # so a read-only member — or a non-member on a public read-only board — cannot
  # persist a create/edit by pushing a "save" event, regardless of what the UI
  # renders. Fail closed: any missing scope/board denies.
  defp modify_authorized?(socket) do
    with %{user: %{} = user} <- Map.get(socket.assigns, :current_scope),
         %{} = board <- socket.assigns[:board] do
      Kanban.Boards.can_modify?(board, user)
    else
      _ -> false
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset),
    do: assign(socket, :form, to_form(changeset))

  defp maybe_assign_technical_details_raw(socket, nil), do: socket

  defp maybe_assign_technical_details_raw(socket, raw) when is_binary(raw) do
    assign(socket, :technical_details_raw, raw)
  end

  # The board LiveView handles {FormComponent, {:saved, task}}.
  defp notify_parent(msg), do: send(self(), {FormComponent, msg})
end
