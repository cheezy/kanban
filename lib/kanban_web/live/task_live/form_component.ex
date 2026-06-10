defmodule KanbanWeb.TaskLive.FormComponent do
  use KanbanWeb, :live_component

  import Ecto.Query
  import KanbanWeb.ReviewReportHelpers, only: [review_panel_visible?: 1]

  alias Kanban.Columns
  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.TaskComment
  alias KanbanWeb.ReviewReportPanel
  alias KanbanWeb.TaskLive.Form.OptionBuilders
  alias KanbanWeb.TaskLive.Form.ParamNormalizer
  alias KanbanWeb.TaskLive.Form.TaskParams

  @impl true
  def update(%{task: task, board: board, action: action} = assigns, socket) do
    task_data = prepare_task_data(task, board, action, assigns)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:task, task_data.task_with_associations)
     |> assign(:column_options, task_data.column_options)
     |> assign(:assignable_users, task_data.assignable_users)
     |> assign(:comment_form, task_data.comment_form)
     |> assign(:goal_options, task_data.goal_options)
     |> assign(:field_visibility, board.field_visibility || %{})
     |> assign(:error_message, nil)
     |> assign_form(task_data.changeset)}
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
    comment_form = to_form(TaskComment.changeset(%TaskComment{}, %{}))

    %{
      task_with_associations: task_with_associations,
      column_options: column_options,
      assignable_users: assignable_users,
      comment_form: comment_form,
      goal_options: goal_options,
      changeset: changeset
    }
  end

  defp load_task_associations(task, :edit_task) when not is_nil(task.id) do
    Tasks.get_task_with_history!(task.id)
    |> Repo.preload(comments: from(c in TaskComment, order_by: [desc: c.id]))
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

    changeset =
      socket.assigns.task
      |> Tasks.Task.changeset(task_params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:error_message, nil)
     |> assign_form(changeset)}
  end

  def handle_event("save", %{"task" => task_params}, socket) do
    task_params = ParamNormalizer.normalize_array_params(task_params)
    save_task(socket, socket.assigns.action, task_params)
  end

  def handle_event("add_comment", %{"task_comment" => comment_params}, socket) do
    if commenter_authorized?(socket) do
      do_add_comment(socket, comment_params)
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext("You must be a board member to comment on this task")
       )}
    end
  end

  def handle_event("add-key-file", _params, socket) do
    existing = Ecto.Changeset.get_field(socket.assigns.form.source, :key_files) || []
    key_files = existing ++ [%Kanban.Schemas.Task.KeyFile{position: length(existing)}]

    changeset =
      socket.assigns.task
      |> Tasks.Task.changeset(%{})
      |> Ecto.Changeset.put_embed(:key_files, key_files)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("remove-key-file", %{"index" => index}, socket) do
    {index, _} = Integer.parse(index)

    key_files =
      (Ecto.Changeset.get_field(socket.assigns.form.source, :key_files) || [])
      |> List.delete_at(index)

    changeset =
      socket.assigns.task
      |> Tasks.Task.changeset(%{})
      |> Ecto.Changeset.put_embed(:key_files, key_files)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("add-verification-step", _params, socket) do
    existing = Ecto.Changeset.get_field(socket.assigns.form.source, :verification_steps) || []
    steps = existing ++ [%Kanban.Schemas.Task.VerificationStep{position: length(existing)}]

    changeset =
      socket.assigns.task
      |> Tasks.Task.changeset(%{})
      |> Ecto.Changeset.put_embed(:verification_steps, steps)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("remove-verification-step", %{"index" => index}, socket) do
    {index, _} = Integer.parse(index)

    steps =
      (Ecto.Changeset.get_field(socket.assigns.form.source, :verification_steps) || [])
      |> List.delete_at(index)

    changeset =
      socket.assigns.task
      |> Tasks.Task.changeset(%{})
      |> Ecto.Changeset.put_embed(:verification_steps, steps)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("add-technology", _params, socket),
    do: handle_add_to_array(socket, :technology_requirements)

  def handle_event("remove-technology", %{"index" => index}, socket),
    do: handle_remove_from_array(socket, :technology_requirements, index)

  def handle_event("add-pitfall", _params, socket), do: handle_add_to_array(socket, :pitfalls)

  def handle_event("remove-pitfall", %{"index" => index}, socket),
    do: handle_remove_from_array(socket, :pitfalls, index)

  def handle_event("add-out-of-scope", _params, socket),
    do: handle_add_to_array(socket, :out_of_scope)

  def handle_event("remove-out-of-scope", %{"index" => index}, socket),
    do: handle_remove_from_array(socket, :out_of_scope, index)

  def handle_event("add-dependency", _params, socket),
    do: handle_add_to_array(socket, :dependencies)

  def handle_event("remove-dependency", %{"index" => index}, socket),
    do: handle_remove_from_array(socket, :dependencies, index)

  def handle_event("add-capability", _params, socket),
    do: handle_add_to_array(socket, :required_capabilities)

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

  def handle_event("remove-capability", %{"index" => index}, socket),
    do: handle_remove_from_array(socket, :required_capabilities, index)

  def handle_event("add-security-consideration", _params, socket),
    do: handle_add_to_array(socket, :security_considerations)

  def handle_event("remove-security-consideration", %{"index" => index}, socket),
    do: handle_remove_from_array(socket, :security_considerations, index)

  def handle_event("add-unit-test", _params, socket),
    do: handle_add_to_map_array(socket, :testing_strategy, "unit_tests")

  def handle_event("remove-unit-test", %{"index" => index}, socket),
    do: handle_remove_from_map_array(socket, :testing_strategy, "unit_tests", index)

  def handle_event("add-integration-test", _params, socket),
    do: handle_add_to_map_array(socket, :testing_strategy, "integration_tests")

  def handle_event("remove-integration-test", %{"index" => index}, socket),
    do: handle_remove_from_map_array(socket, :testing_strategy, "integration_tests", index)

  def handle_event("add-manual-test", _params, socket),
    do: handle_add_to_map_array(socket, :testing_strategy, "manual_tests")

  def handle_event("remove-manual-test", %{"index" => index}, socket),
    do: handle_remove_from_map_array(socket, :testing_strategy, "manual_tests", index)

  def handle_event("add-telemetry-event", _params, socket),
    do: handle_add_to_map_array(socket, :integration_points, "telemetry_events")

  def handle_event("remove-telemetry-event", %{"index" => index}, socket),
    do: handle_remove_from_map_array(socket, :integration_points, "telemetry_events", index)

  def handle_event("add-pubsub-broadcast", _params, socket),
    do: handle_add_to_map_array(socket, :integration_points, "pubsub_broadcasts")

  def handle_event("remove-pubsub-broadcast", %{"index" => index}, socket),
    do: handle_remove_from_map_array(socket, :integration_points, "pubsub_broadcasts", index)

  def handle_event("add-phoenix-channel", _params, socket),
    do: handle_add_to_map_array(socket, :integration_points, "phoenix_channels")

  def handle_event("remove-phoenix-channel", %{"index" => index}, socket),
    do: handle_remove_from_map_array(socket, :integration_points, "phoenix_channels", index)

  def handle_event("add-external-api", _params, socket),
    do: handle_add_to_map_array(socket, :integration_points, "external_apis")

  def handle_event("remove-external-api", %{"index" => index}, socket),
    do: handle_remove_from_map_array(socket, :integration_points, "external_apis", index)

  defp handle_add_to_array(socket, field) do
    existing = Ecto.Changeset.get_field(socket.assigns.form.source, field) || []
    new_list = existing ++ [""]

    changeset =
      socket.assigns.task
      |> Tasks.Task.changeset(%{})
      |> Ecto.Changeset.put_change(field, new_list)

    {:noreply, assign_form(socket, changeset)}
  end

  defp handle_remove_from_array(socket, field, index) do
    {index, _} = Integer.parse(index)

    list =
      (Ecto.Changeset.get_field(socket.assigns.form.source, field) || []) |> List.delete_at(index)

    changeset =
      socket.assigns.task
      |> Tasks.Task.changeset(%{})
      |> Ecto.Changeset.put_change(field, list)

    {:noreply, assign_form(socket, changeset)}
  end

  defp handle_add_to_map_array(socket, field, key) do
    existing_map = Ecto.Changeset.get_field(socket.assigns.form.source, field) || %{}
    existing_list = Map.get(existing_map, key, [])
    new_list = existing_list ++ [""]
    new_map = Map.put(existing_map, key, new_list)

    changeset =
      socket.assigns.task
      |> Tasks.Task.changeset(%{})
      |> Ecto.Changeset.put_change(field, new_map)

    {:noreply, assign_form(socket, changeset)}
  end

  defp handle_remove_from_map_array(socket, field, key, index) do
    {index, _} = Integer.parse(index)
    existing_map = Ecto.Changeset.get_field(socket.assigns.form.source, field) || %{}
    existing_list = Map.get(existing_map, key, [])
    new_list = List.delete_at(existing_list, index)
    new_map = Map.put(existing_map, key, new_list)

    changeset =
      socket.assigns.task
      |> Tasks.Task.changeset(%{})
      |> Ecto.Changeset.put_change(field, new_map)

    {:noreply, assign_form(socket, changeset)}
  end

  defp save_task(socket, :edit_task, task_params) do
    # Security: every relational field that the user can change via the
    # form must be verified to live on the current board. The existing
    # column_id check is preserved; parent_id and assigned_to_id are now
    # validated the same way. Each check is independent — a single bad
    # field rejects the whole save with a targeted changeset error.
    case validate_relational_scopes(socket, task_params) do
      :ok ->
        perform_task_update(socket, task_params)

      {:error, field, message} ->
        changeset =
          socket.assigns.task
          |> Tasks.Task.changeset(task_params)
          |> Ecto.Changeset.add_error(field, message)

        {:noreply,
         socket
         |> assign(:error_message, TaskParams.scope_error_label(field))
         |> assign_form(changeset)}
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

  defp validate_relational_scopes(socket, task_params) do
    board = socket.assigns.board

    with :ok <- validate_column_scope(task_params, board),
         :ok <- validate_parent_scope(task_params, board) do
      validate_assigned_to_scope(task_params, board)
    end
  end

  defp validate_column_scope(task_params, board) do
    case Map.get(task_params, "column_id") do
      nil ->
        :ok

      "" ->
        :ok

      column_id ->
        column = Columns.get_column!(column_id)

        if column.board_id == board.id do
          :ok
        else
          {:error, :column_id, gettext("Column does not belong to this board")}
        end
    end
  end

  defp validate_parent_scope(task_params, board) do
    case Map.get(task_params, "parent_id") do
      nil ->
        :ok

      "" ->
        :ok

      parent_id_input ->
        with {:ok, parent_id} <- TaskParams.coerce_id(parent_id_input),
             %{} <- Tasks.get_task_for_board(parent_id, board.id) do
          :ok
        else
          _ -> {:error, :parent_id, gettext("Parent goal does not belong to this board")}
        end
    end
  end

  defp validate_assigned_to_scope(task_params, board) do
    case Map.get(task_params, "assigned_to_id") do
      nil ->
        :ok

      "" ->
        :ok

      assigned_input ->
        with {:ok, user_id} <- TaskParams.coerce_id(assigned_input),
             true <- board_member?(board, user_id) do
          :ok
        else
          _ -> {:error, :assigned_to_id, gettext("Assignee does not have access to this board")}
        end
    end
  end

  # Called from validate_assigned_to_scope/2; analyzer regex misses predicate `?` callers.
  defp board_member?(board, user_id) do
    not is_nil(Kanban.Boards.get_user_access(board.id, user_id))
  end

  defp perform_task_update(socket, task_params) do
    task_params = prepare_task_update_params(socket, task_params)
    cascade_count = TaskParams.compute_cascade_count(socket.assigns.task, task_params)

    case Tasks.update_task(socket.assigns.task, task_params) do
      {:ok, task} ->
        notify_parent({:saved, task})

        {:noreply,
         socket
         |> put_flash(:info, TaskParams.build_update_flash(cascade_count))
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:error_message, gettext("Please fix the errors below"))
         |> assign_form(changeset)}
    end
  end

  defp prepare_task_update_params(socket, task_params) do
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

  defp do_add_comment(socket, comment_params) do
    # Always source task_id from the server-held task — overwrites any
    # client-supplied task_id in comment_params.
    comment_params = Map.put(comment_params, "task_id", socket.assigns.task.id)

    case %TaskComment{}
         |> TaskComment.changeset(comment_params)
         |> Repo.insert() do
      {:ok, _comment} ->
        {:noreply, assign_after_comment_added(socket)}

      {:error, changeset} ->
        {:noreply, assign(socket, :comment_form, to_form(changeset))}
    end
  end

  defp assign_after_comment_added(socket) do
    task =
      Tasks.get_task_with_history!(socket.assigns.task.id)
      |> Repo.preload(comments: from(c in TaskComment, order_by: [desc: c.id]))

    comment_changeset = TaskComment.changeset(%TaskComment{}, %{})

    socket
    |> assign(:task, task)
    |> assign(:comment_form, to_form(comment_changeset))
    |> put_flash(:info, gettext("Comment added successfully"))
  end

  # Authorization gate for add_comment: caller must be a member of the
  # board the task lives on. Read-only members are allowed (commenting
  # is discussion, not state mutation). Public/unauthenticated viewers
  # and authenticated users with no membership row are rejected. Note:
  # the TaskComment schema currently has no author/user_id field, so
  # spoofing the author via comment_params is structurally impossible —
  # this gate covers the second half of the security review's concern
  # ("verify the user is authorized to comment on socket.assigns.task").
  # Called from handle_event("add_comment", ...); analyzer regex misses
  # predicate `?` callers, hence the unused-defp false positive.
  defp commenter_authorized?(socket) do
    with %{user: %{id: user_id}} <- Map.get(socket.assigns, :current_scope),
         %{} = board <- socket.assigns[:board],
         access when not is_nil(access) <-
           Kanban.Boards.get_user_access(board.id, user_id) do
      true
    else
      _ -> false
    end
  end

  # Used in form_component.html.heex (analyzer does not scan HEEx files).
  defp ensure_list(nil), do: []
  defp ensure_list(value) when is_list(value), do: value
  defp ensure_list(value) when is_binary(value), do: [value]
  defp ensure_list(_value), do: []
end
