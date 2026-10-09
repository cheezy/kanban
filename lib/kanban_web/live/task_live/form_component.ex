defmodule KanbanWeb.TaskLive.FormComponent do
  use KanbanWeb, :live_component

  import KanbanWeb.ReviewReportHelpers.Panels, only: [review_panel_visible?: 1]
  import KanbanWeb.TaskLive.Form.EmbedSections, only: [embed_sections: 1]
  import KanbanWeb.TaskLive.Form.GuidanceSections, only: [guidance_sections: 1]
  import KanbanWeb.TaskLive.Form.LabelPicker, only: [label_picker: 1]
  import KanbanWeb.TaskLive.Form.PlanningSections, only: [planning_sections: 1]

  alias Kanban.Columns
  alias Kanban.Tasks
  alias KanbanWeb.ReviewReportPanel
  alias KanbanWeb.TaskLive.Form.FieldEvents
  alias KanbanWeb.TaskLive.Form.LabelSelection
  alias KanbanWeb.TaskLive.Form.OptionBuilders
  alias KanbanWeb.TaskLive.Form.ParamNormalizer
  alias KanbanWeb.TaskLive.Form.RelationalScopes
  alias KanbanWeb.TaskLive.Form.TaskParams
  alias KanbanWeb.TaskLive.Form.TechnicalDetails

  @field_events FieldEvents.events()

  # The board's labels changed while the form was open (sent by
  # KanbanWeb.BoardLive.BoardEvents); only the label picker is rebuilt.
  @impl true
  def update(%{refresh_labels: true}, socket),
    do: {:ok, LabelSelection.refresh_options(socket)}

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
    assign(socket,
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
  end

  defp prepare_task_data(task, board, action, assigns) do
    columns = Columns.list_columns(board)
    column_id = OptionBuilders.get_column_id(assigns, task)
    changeset = OptionBuilders.build_changeset(task, column_id, action)
    column_options = OptionBuilders.build_column_options(columns, task)

    board_users = Kanban.Boards.list_board_users(board)
    assignable_users = OptionBuilders.build_assignable_users_options(board_users)

    goal_options = OptionBuilders.build_goal_options(board, task)

    task_with_associations = load_task_associations(task, action)

    %{
      task_with_associations: task_with_associations,
      column_options: column_options,
      assignable_users: assignable_users,
      goal_options: goal_options,
      changeset: changeset
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

  def handle_event("save", %{"task" => task_params}, socket) do
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

  def handle_event("add-key-file", _params, socket) do
    existing = Ecto.Changeset.get_field(socket.assigns.form.source, :key_files) || []
    key_files = existing ++ [%Kanban.Schemas.Task.KeyFile{position: length(existing)}]

    put_embed_rows(socket, :key_files, key_files)
  end

  def handle_event("remove-key-file", %{"index" => index}, socket) do
    {index, _} = Integer.parse(index)

    key_files =
      (Ecto.Changeset.get_field(socket.assigns.form.source, :key_files) || [])
      |> List.delete_at(index)

    put_embed_rows(socket, :key_files, key_files)
  end

  def handle_event("add-verification-step", _params, socket) do
    existing = Ecto.Changeset.get_field(socket.assigns.form.source, :verification_steps) || []
    steps = existing ++ [%Kanban.Schemas.Task.VerificationStep{position: length(existing)}]

    put_embed_rows(socket, :verification_steps, steps)
  end

  def handle_event("remove-verification-step", %{"index" => index}, socket) do
    {index, _} = Integer.parse(index)

    steps =
      (Ecto.Changeset.get_field(socket.assigns.form.source, :verification_steps) || [])
      |> List.delete_at(index)

    put_embed_rows(socket, :verification_steps, steps)
  end

  def handle_event("add-behaviour-test-row", _params, socket) do
    existing = Ecto.Changeset.get_field(socket.assigns.form.source, :behaviour_test_matrix) || []
    rows = existing ++ [%Kanban.Schemas.Task.BehaviourTestRow{position: length(existing)}]

    put_embed_rows(socket, :behaviour_test_matrix, rows)
  end

  def handle_event("remove-behaviour-test-row", %{"index" => index}, socket) do
    {index, _} = Integer.parse(index)

    rows =
      (Ecto.Changeset.get_field(socket.assigns.form.source, :behaviour_test_matrix) || [])
      |> List.delete_at(index)

    put_embed_rows(socket, :behaviour_test_matrix, rows)
  end

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

  # Only refresh the raw assign when the textarea actually posted (field visible);
  # when absent, keep the value set in update/2.
  defp maybe_assign_technical_details_raw(socket, nil), do: socket

  defp maybe_assign_technical_details_raw(socket, raw) when is_binary(raw) do
    assign(socket, :technical_details_raw, raw)
  end

  # Runs the actual create/edit once modify access has been authorized in the
  # "save" handle_event (D110).
  defp do_save_task(socket, task_params) do
    task_params = ParamNormalizer.normalize_array_params(task_params)
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
    case RelationalScopes.validate(task_params, socket.assigns.board) do
      :ok ->
        perform_task_update(socket, task_params)

      {:error, field, message} ->
        reject_with_scope_error(socket, task_params, field, message)
    end
  end

  defp save_task(socket, :new_task, task_params) do
    column_id = task_params["column_id"] || socket.assigns.column_id

    column = Columns.get_column!(column_id)

    # Security: Verify column belongs to the current board
    if column.board_id != socket.assigns.board.id do
      changeset =
        socket.assigns.task
        |> Tasks.Task.changeset(task_params)
        |> Ecto.Changeset.add_error(:column_id, gettext("Column does not belong to this board"))

      {:noreply,
       socket
       |> assign(:error_message, gettext("Security error: Invalid column"))
       |> assign_form(changeset)}
    else
      create_task_in_column(socket, column, task_params)
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
        socket = LabelSelection.apply_change(socket, task)
        notify_parent({:saved, task})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Task created successfully"))
         |> push_patch(to: socket.assigns.patch)}

      {:error, :wip_limit_reached} ->
        handle_wip_limit_reached(socket, task_params)

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:error_message, gettext("Please fix the errors below"))
         |> assign_form(changeset)}
    end
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

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    socket
    |> assign(:form, to_form(changeset))
  end

  # W403: review attribution and completion timestamps are server-owned audit
  # fields. The previous Map.put_new / Map.has_key? pattern let a board member
  # forge them via a crafted form payload (CWE-639). Now we ALWAYS overwrite
  # those keys with server values when the status transition fires, and we
  # drop any client-supplied version up front so even non-transition saves do
  # not let a malicious client persist forged values. Exposed via @doc false so
  # the regression test in form_component_test.exs can exercise the logic
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

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})

  # D110: the task create/edit save path is a modify action. Board access is
  # verified authoritatively here (current_scope + board -> Boards.can_modify?)
  # so a read-only member — or a non-member on a public read-only board — cannot
  # persist a create/edit by pushing a "save" event, regardless of what the UI
  # renders. Fail closed: any missing scope/board denies. Called from
  # handle_event("save", ...); the analyzer regex misses predicate `?` callers.
  defp modify_authorized?(socket) do
    with %{user: %{} = user} <- Map.get(socket.assigns, :current_scope),
         %{} = board <- socket.assigns[:board] do
      Kanban.Boards.can_modify?(board, user)
    else
      _ -> false
    end
  end

  # Used in form_component.html.heex (analyzer does not scan HEEx files).
end
