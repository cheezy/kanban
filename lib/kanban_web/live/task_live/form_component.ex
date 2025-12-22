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
     |> assign(:field_visibility, board.field_visibility || %{})
     |> assign_form(task_data.changeset)}
  end

  defp prepare_task_data(task, board, action, assigns) do
    columns = Columns.list_columns(board)
    column_id = get_column_id(assigns, task)
    changeset = build_changeset(task, column_id)
    column_options = build_column_options(columns, task)

    board_users = Kanban.Boards.list_board_users(board)
    assignable_users = build_assignable_users_options(board_users)

    task_with_associations = load_task_associations(task, action)
    comment_form = to_form(TaskComment.changeset(%TaskComment{}, %{}))

    %{
      task_with_associations: task_with_associations,
      column_options: column_options,
      assignable_users: assignable_users,
      comment_form: comment_form,
      changeset: changeset
    }
  end

  defp load_task_associations(task, :edit_task) when not is_nil(task.id) do
    Tasks.get_task_with_history!(task.id)
    |> Repo.preload(comments: from(c in TaskComment, order_by: [desc: c.id]))
  end

  defp load_task_associations(task, _action), do: task

  defp field_visible?(field_visibility, field_name) do
    Map.get(field_visibility, field_name, false)
  end

  @impl true
  def handle_event("validate", %{"task" => task_params}, socket) do
    changeset =
      socket.assigns.task
      |> Tasks.Task.changeset(task_params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"task" => task_params}, socket) do
    save_task(socket, socket.assigns.action, task_params)
  end

  def handle_event("add_comment", %{"task_comment" => comment_params}, socket) do
    comment_params = Map.put(comment_params, "task_id", socket.assigns.task.id)

    case %TaskComment{}
         |> TaskComment.changeset(comment_params)
         |> Repo.insert() do
      {:ok, _comment} ->
        # Reload task with updated comments
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

  def handle_event("remove-capability", %{"index" => index}, socket),
    do: handle_remove_from_array(socket, :required_capabilities, index)

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

  defp save_task(socket, :edit_task, task_params) do
    case Tasks.update_task(socket.assigns.task, task_params) do
      {:ok, task} ->
        notify_parent({:saved, task})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Task updated successfully"))
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_task(socket, :new_task, task_params) do
    column_id = task_params["column_id"] || socket.assigns.column_id

    column = Columns.get_column!(column_id)

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

        {:noreply, assign_form(socket, changeset)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})

  defp get_column_id(%{column_id: col_id}, _task) when not is_nil(col_id), do: col_id
  defp get_column_id(_assigns, task), do: task.column_id

  defp build_changeset(task, nil), do: Tasks.Task.changeset(task, %{})

  defp build_changeset(task, column_id) do
    task
    |> Tasks.Task.changeset(%{})
    |> Ecto.Changeset.put_change(:column_id, column_id)
  end

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
end
