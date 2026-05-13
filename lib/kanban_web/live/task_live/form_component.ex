defmodule KanbanWeb.TaskLive.FormComponent do
  use KanbanWeb, :live_component

  import Ecto.Query

  alias Kanban.Columns
  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.TaskComment

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
    column_id = get_column_id(assigns, task)
    changeset = build_changeset(task, column_id, action)
    column_options = build_column_options(columns, task)

    board_users = Kanban.Boards.list_board_users(board)
    assignable_users = build_assignable_users_options(board_users)

    goal_options = build_goal_options(board, task)

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
    task_params = normalize_array_params(task_params)

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
    task_params = normalize_array_params(task_params)
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
         |> assign(:error_message, scope_error_label(field))
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
        with {:ok, parent_id} <- coerce_id(parent_id_input),
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
        with {:ok, user_id} <- coerce_id(assigned_input),
             true <- board_member?(board, user_id) do
          :ok
        else
          _ -> {:error, :assigned_to_id, gettext("Assignee does not have access to this board")}
        end
    end
  end

  defp coerce_id(id) when is_integer(id), do: {:ok, id}

  defp coerce_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp coerce_id(_), do: :error

  # Called from validate_assigned_to_scope/2; analyzer regex misses predicate `?` callers.
  defp board_member?(board, user_id) do
    not is_nil(Kanban.Boards.get_user_access(board.id, user_id))
  end

  defp scope_error_label(:column_id), do: gettext("Security error: Invalid column")
  defp scope_error_label(:parent_id), do: gettext("Security error: Invalid parent goal")
  defp scope_error_label(:assigned_to_id), do: gettext("Security error: Invalid assignee")

  defp perform_task_update(socket, task_params) do
    # Auto-populate review fields when review_status changes
    task_params =
      case Map.get(socket.assigns, :current_scope) do
        %{user: user} -> maybe_add_review_metadata(task_params, user)
        _ -> task_params
      end

    # Auto-populate completed_at when status is set to completed
    task_params = maybe_add_completed_at(task_params, socket.assigns.task)

    cascade_count = compute_cascade_count(socket.assigns.task, task_params)

    case Tasks.update_task(socket.assigns.task, task_params) do
      {:ok, task} ->
        notify_parent({:saved, task})

        {:noreply,
         socket
         |> put_flash(:info, build_update_flash(cascade_count))
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:error_message, gettext("Please fix the errors below"))
         |> assign_form(changeset)}
    end
  end

  # When a goal's `assigned_to_id` is being changed, ask the Tasks context how
  # many non-completed children will inherit the new assignment via the
  # cascade in `Lifecycle.update_task/2`. The count is computed BEFORE the
  # cascade runs, so it reflects the eligible-children set the cascade will
  # touch. Returns 0 for non-goal tasks or when assignment is unchanged.
  defp compute_cascade_count(task, task_params) do
    if task.type == :goal and Map.has_key?(task_params, "assigned_to_id") do
      target = parse_assignment_target(task_params["assigned_to_id"])
      Tasks.count_cascade_affected_children(task, target)
    else
      0
    end
  end

  defp parse_assignment_target(nil), do: nil
  defp parse_assignment_target(""), do: nil
  defp parse_assignment_target(value) when is_integer(value), do: value

  defp parse_assignment_target(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_assignment_target(_), do: nil

  defp build_update_flash(0), do: gettext("Task updated successfully")

  defp build_update_flash(n) when n > 0 do
    ngettext(
      "Task updated successfully. 1 child task was also updated.",
      "Task updated successfully. %{count} child tasks were also updated.",
      n
    )
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
        changeset =
          socket.assigns.task
          |> Tasks.Task.changeset(task_params)
          |> Ecto.Changeset.add_error(:column_id, gettext("WIP limit reached for this column"))

        {:noreply,
         socket
         |> assign(:error_message, gettext("Cannot add task: WIP limit reached for this column"))
         |> assign_form(changeset)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:error_message, gettext("Please fix the errors below"))
         |> assign_form(changeset)}
    end
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

  defp normalize_array_params(params) do
    array_fields = [
      "dependencies",
      "required_capabilities",
      "technology_requirements",
      "pitfalls",
      "out_of_scope",
      "security_considerations"
    ]

    params
    |> normalize_array_fields(array_fields)
    |> normalize_map_fields()
  end

  defp normalize_array_fields(params, fields) do
    Enum.reduce(fields, params, fn field, acc ->
      # Only normalize if the field is actually present in params
      # Don't add missing fields - that would incorrectly trigger change detection
      if Map.has_key?(acc, field) do
        Map.update(acc, field, [], &filter_empty_strings/1)
      else
        acc
      end
    end)
  end

  defp normalize_map_fields(params) do
    params
    |> normalize_testing_strategy()
    |> normalize_integration_points()
    |> normalize_embedded_fields()
  end

  defp normalize_embedded_fields(params) do
    params
    |> normalize_embedded_field("key_files")
    |> normalize_embedded_field("verification_steps")
  end

  defp normalize_embedded_field(params, field_name) do
    case Map.get(params, field_name) do
      # If it's already a list, leave it as is
      value when is_list(value) ->
        params

      # If it's a map with numeric string keys (from inputs_for), convert to list
      value when is_map(value) ->
        list =
          value
          |> Enum.sort_by(fn {k, _v} -> String.to_integer(k) end)
          |> Enum.map(fn {_k, v} -> Map.delete(v, "_persistent_id") end)

        Map.put(params, field_name, list)

      # If it's nil or missing, don't add it to params
      # Schema defaults will handle nil values appropriately
      # Adding empty arrays here would incorrectly trigger change detection
      _ ->
        params
    end
  end

  defp normalize_testing_strategy(params) do
    normalize_map_with_arrays(params, "testing_strategy", [
      "unit_tests",
      "integration_tests",
      "manual_tests"
    ])
  end

  defp normalize_integration_points(params) do
    normalize_map_with_arrays(params, "integration_points", [
      "telemetry_events",
      "pubsub_broadcasts",
      "phoenix_channels",
      "external_apis"
    ])
  end

  defp normalize_map_with_arrays(params, field_name, array_keys) do
    case Map.get(params, field_name) do
      # If field is present and is a map, normalize its array fields
      field_map when is_map(field_map) ->
        normalized_map = normalize_array_fields(field_map, array_keys)
        Map.put(params, field_name, normalized_map)

      # If it's nil or missing, don't add it to params
      # Schema defaults will handle nil values appropriately
      # Adding default maps here would incorrectly trigger change detection
      _ ->
        params
    end
  end

  defp filter_empty_strings(list) when is_list(list) do
    Enum.reject(list, &(&1 == "" || is_nil(&1)))
  end

  defp filter_empty_strings(value), do: value

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})

  defp do_add_comment(socket, comment_params) do
    # Always source task_id from the server-held task — overwrites any
    # client-supplied task_id in comment_params.
    comment_params = Map.put(comment_params, "task_id", socket.assigns.task.id)

    case %TaskComment{}
         |> TaskComment.changeset(comment_params)
         |> Repo.insert() do
      {:ok, _comment} ->
        task =
          Tasks.get_task_with_history!(socket.assigns.task.id)
          |> Repo.preload(comments: from(c in TaskComment, order_by: [desc: c.id]))

        comment_changeset = TaskComment.changeset(%TaskComment{}, %{})

        {:noreply,
         socket
         |> assign(:task, task)
         |> assign(:comment_form, to_form(comment_changeset))
         |> put_flash(:info, gettext("Comment added successfully"))}

      {:error, changeset} ->
        {:noreply, assign(socket, :comment_form, to_form(changeset))}
    end
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

  defp get_column_id(%{column_id: col_id}, _task) when not is_nil(col_id), do: col_id
  defp get_column_id(_assigns, task), do: task.column_id

  defp build_changeset(task, nil, action) do
    task
    |> Tasks.Task.changeset(%{})
    |> maybe_default_human_task(action)
  end

  defp build_changeset(task, column_id, action) do
    task
    |> Tasks.Task.changeset(%{})
    |> Ecto.Changeset.put_change(:column_id, column_id)
    |> maybe_default_human_task(action)
  end

  defp maybe_default_human_task(changeset, :new_task) do
    Ecto.Changeset.put_change(changeset, :human_task, true)
  end

  defp maybe_default_human_task(changeset, _action), do: changeset

  defp build_column_options(columns, task) do
    columns
    |> Enum.map(&column_option(&1, task))
    |> Enum.reject(&reject_full_column?(&1, task))
  end

  defp column_option(column, task) do
    can_add = Tasks.can_add_task?(column)

    label =
      if can_add || column.id == task.column_id do
        column.name
      else
        "#{column.name} (WIP limit reached)"
      end

    {label, column.id}
  end

  # Passed as capture to Enum.reject/2 in build_column_options/2; analyzer regex misses predicate `?` callers.
  defp reject_full_column?({label, id}, task) do
    String.contains?(label, "WIP limit reached") && id != task.column_id
  end

  defp build_assignable_users_options(board_users) do
    users_list =
      board_users
      |> Enum.map(fn %{user: user} ->
        display_name = if user.name && user.name != "", do: user.name, else: user.email
        {display_name, user.id}
      end)

    [{gettext("Unassigned"), nil} | users_list]
  end

  defp build_goal_options(board, task) do
    goals =
      from(t in Tasks.Task,
        join: c in assoc(t, :column),
        where: c.board_id == ^board.id,
        where: t.type == :goal,
        where: t.id != ^(task.id || 0),
        order_by: [asc: t.identifier],
        select: {t.identifier, t.title, t.id}
      )
      |> Repo.all()
      |> Enum.map(fn {identifier, title, id} ->
        {"#{identifier} - #{title}", id}
      end)

    [{gettext("No parent goal"), nil} | goals]
  end

  # Used in form_component.html.heex (analyzer does not scan HEEx files).
  defp ensure_list(nil), do: []
  defp ensure_list(value) when is_list(value), do: value
  defp ensure_list(value) when is_binary(value), do: [value]
  defp ensure_list(_value), do: []
end
