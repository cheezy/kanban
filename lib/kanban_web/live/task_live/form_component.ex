defmodule KanbanWeb.TaskLive.FormComponent do
  use KanbanWeb, :live_component

  import KanbanWeb.ReviewReportHelpers.Panels, only: [review_panel_visible?: 1]
  import KanbanWeb.TaskLive.Form.EmbedSections, only: [embed_sections: 1]
  import KanbanWeb.TaskLive.Form.GuidanceSections, only: [guidance_sections: 1]
  import KanbanWeb.TaskLive.Form.LabelPicker, only: [label_picker: 1]
  import KanbanWeb.TaskLive.Form.PlanningSections, only: [planning_sections: 1]

  alias Kanban.Columns
  alias Kanban.Tasks
  alias KanbanWeb.IdParams
  alias KanbanWeb.ReviewReportPanel
  alias KanbanWeb.TaskLive.Form.AttachmentStaging
  alias KanbanWeb.TaskLive.Form.FieldEvents
  alias KanbanWeb.TaskLive.Form.LabelSelection
  alias KanbanWeb.TaskLive.Form.OptionBuilders
  alias KanbanWeb.TaskLive.Form.ParamNormalizer
  alias KanbanWeb.TaskLive.Form.Save
  alias KanbanWeb.TaskLive.Form.TechnicalDetails
  alias KanbanWeb.TaskLive.Form.TelemetryLock

  @field_events FieldEvents.events()

  # The board's labels changed while the form was open (sent by
  # KanbanWeb.BoardLive.BoardEvents); only the label picker is rebuilt.
  @impl true
  def update(%{refresh_labels: true}, socket),
    do: {:ok, LabelSelection.refresh_options(socket)}

  # The board moved into or out of an Organization while the form was open
  # (sent by BoardEvents), so the plan-gated fields follow its new plan.
  def update(%{refresh_plan: true}, %{assigns: %{board: board, action: action}} = socket),
    do:
      {:ok,
       socket |> TelemetryLock.assign_locked(board) |> AttachmentStaging.allow(board, action)}

  # A re-render of the hosting LiveView (a flash, for example) can re-send the
  # same task. Rebuilding the form from it would throw away what the user has
  # typed, so keep the form unless the stored task itself changed.
  def update(
        %{task: %{id: id, updated_at: updated_at}, board: board} = assigns,
        %{assigns: %{form: _, task: %{id: id, updated_at: updated_at}}} = socket
      )
      when not is_nil(id) do
    {:ok,
     socket
     |> assign(Map.drop(assigns, [:task]))
     |> assign(:field_visibility, board.field_visibility || %{})}
  end

  def update(%{task: task, board: board, action: action} = assigns, socket) do
    task_data = prepare_task_data(task, board, action, assigns)

    {:ok,
     socket
     |> assign(assigns)
     |> assign_task_data(task_data)
     |> assign_new(:current_scope, fn -> nil end)
     |> assign_labels_and_visibility(assigns, task, action)
     |> assign(:error_message, nil)
     |> assign(:technical_details_raw, TechnicalDetails.encode(task_data.changeset))
     |> assign_form(task_data.changeset)}
  end

  defp assign_task_data(socket, task_data) do
    socket
    |> ReviewReportPanel.track_view(task_data.review_task)
    |> assign(
      task: task_data.task_with_associations,
      column_options: task_data.column_options,
      assignable_users: task_data.assignable_users,
      goal_options: task_data.goal_options
    )
  end

  defp assign_labels_and_visibility(socket, %{board: board} = assigns, task, action) do
    socket
    |> LabelSelection.assign_options(assigns[:current_scope], board, task, action)
    |> assign(:field_visibility, board.field_visibility || %{})
    |> TelemetryLock.assign_locked(board)
    |> AttachmentStaging.allow(board, action)
  end

  defp prepare_task_data(task, board, action, assigns) do
    columns = Columns.list_columns(board)
    column_id = OptionBuilders.get_column_id(assigns, task)
    changeset = OptionBuilders.build_changeset(task, column_id, action)
    column_options = OptionBuilders.build_column_options(columns, task)

    board_users = OptionBuilders.assignable_board_users(board)
    assignable_users = OptionBuilders.build_assignable_users_options(board_users, task)

    goal_options = OptionBuilders.build_goal_options(board, task)

    task_with_associations = load_task_associations(task, action)

    %{
      task_with_associations: task_with_associations,
      column_options: column_options,
      assignable_users: assignable_users,
      goal_options: goal_options,
      changeset: changeset,
      # Only the edit form shows the task's review report.
      review_task: if(action == :edit_task, do: task)
    }
  end

  # Comments are loaded by the CommentThreadComponent the template mounts.
  defp load_task_associations(task, :edit_task) when not is_nil(task.id) do
    Tasks.get_task_with_history!(task.id)
  end

  defp load_task_associations(task, _action), do: task

  # Used in form_component.html.heex (analyzer does not scan HEEx files).
  defp field_visible?(field_visibility, field_name) do
    Map.get(field_visibility, field_name, false)
  end

  @impl true
  def handle_event("validate", %{"task" => task_params}, socket) do
    # Normalize params before validation to avoid false validation errors
    task_params = ParamNormalizer.normalize_array_params(task_params)
    raw = Map.get(task_params, "technical_details")

    {decoded_params, td_error} = TechnicalDetails.decode_for_changeset(task_params)

    changeset =
      socket.assigns.task
      |> Tasks.Task.changeset(decoded_params)
      |> TechnicalDetails.maybe_add_error(td_error)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:error_message, nil)
     |> LabelSelection.track(task_params)
     |> maybe_assign_technical_details_raw(raw)
     |> assign_form(changeset)}
  end

  # The create/edit itself, from the D110 modify check on, is
  # KanbanWeb.TaskLive.Form.Save.
  def handle_event("save", %{"task" => task_params}, socket),
    do: Save.save(socket, task_params)

  def handle_event("add-key-file", _params, socket) do
    existing = Ecto.Changeset.get_field(socket.assigns.form.source, :key_files) || []
    key_files = existing ++ [%Kanban.Schemas.Task.KeyFile{position: length(existing)}]

    put_embed_rows(socket, :key_files, key_files)
  end

  def handle_event("remove-key-file", params, socket),
    do: remove_embed_row(socket, :key_files, params["index"])

  def handle_event("add-verification-step", _params, socket) do
    existing = Ecto.Changeset.get_field(socket.assigns.form.source, :verification_steps) || []
    steps = existing ++ [%Kanban.Schemas.Task.VerificationStep{position: length(existing)}]

    put_embed_rows(socket, :verification_steps, steps)
  end

  def handle_event("remove-verification-step", params, socket),
    do: remove_embed_row(socket, :verification_steps, params["index"])

  def handle_event("add-behaviour-test-row", _params, socket) do
    existing = Ecto.Changeset.get_field(socket.assigns.form.source, :behaviour_test_matrix) || []
    rows = existing ++ [%Kanban.Schemas.Task.BehaviourTestRow{position: length(existing)}]

    put_embed_rows(socket, :behaviour_test_matrix, rows)
  end

  def handle_event("remove-behaviour-test-row", params, socket),
    do: remove_embed_row(socket, :behaviour_test_matrix, params["index"])

  def handle_event("add-capability-from-select", %{"new_capability" => capability}, socket)
      when capability != "" do
    changeset = socket.assigns.form.source
    current_capabilities = Ecto.Changeset.get_field(changeset, :required_capabilities) || []

    # Don't add duplicates
    if capability in current_capabilities do
      {:noreply, socket}
    else
      updated_capabilities = current_capabilities ++ [capability]

      updated_changeset =
        changeset
        |> Ecto.Changeset.put_change(:required_capabilities, updated_capabilities)

      {:noreply, assign(socket, form: to_form(updated_changeset))}
    end
  end

  def handle_event("add-capability-from-select", _params, socket), do: {:noreply, socket}

  def handle_event("cancel-attachment", params, socket),
    do: {:noreply, AttachmentStaging.cancel(socket, params["ref"])}

  # Every remaining add-/remove- row event is table-driven; see
  # KanbanWeb.TaskLive.Form.FieldEvents. Guarding on the table keeps unmapped
  # events a FunctionClauseError instead of silently doing nothing.
  def handle_event(event, params, socket) when is_map_key(@field_events, event) do
    FieldEvents.handle(event, params, socket)
  end

  # Builds on the in-flight form (kept current by phx-change="validate"), so
  # adding or removing a row keeps the user's other unsaved edits.
  defp put_embed_rows(socket, field, rows) do
    changeset = Ecto.Changeset.put_embed(socket.assigns.form.source, field, rows)
    {:noreply, assign_form(socket, changeset)}
  end

  # The index comes from the client, so a crafted one (non-numeric, negative
  # or oversized) changes nothing rather than crashing the form (D384).
  defp remove_embed_row(socket, field, index) do
    case IdParams.parse_index(index) do
      {:ok, index} ->
        rows = Ecto.Changeset.get_field(socket.assigns.form.source, field) || []
        put_embed_rows(socket, field, List.delete_at(rows, index))

      :error ->
        {:noreply, socket}
    end
  end

  # Only refresh the raw assign when the textarea actually posted (field visible);
  # when absent, keep the value set in update/2.
  defp maybe_assign_technical_details_raw(socket, nil), do: socket

  defp maybe_assign_technical_details_raw(socket, raw) when is_binary(raw) do
    assign(socket, :technical_details_raw, raw)
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    socket
    |> assign(:form, to_form(changeset))
  end

  # Used in form_component.html.heex (analyzer does not scan HEEx files).
  # An assignment history row's user is nil once that user is deleted (the
  # foreign keys nilify), so the name falls back as in TaskActivityLog.
  defp history_user_name(%{name: name}) when is_binary(name), do: name
  defp history_user_name(_user), do: gettext("Unknown")
end
