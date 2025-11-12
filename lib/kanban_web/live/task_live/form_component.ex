defmodule KanbanWeb.TaskLive.FormComponent do
  use KanbanWeb, :live_component

  import Ecto.Query

  alias Kanban.Columns
  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.TaskComment

  @impl true
  def update(%{task: task, board: board, action: action} = assigns, socket) do
    columns = Columns.list_columns(board)
    column_id = get_column_id(assigns, task)
    changeset = build_changeset(task, column_id)
    column_options = build_column_options(columns, task)

    # Preload task histories and comments when editing
    task_with_associations =
      if action == :edit_task && task.id do
        Tasks.get_task_with_history!(task.id)
        |> Repo.preload(comments: from(c in TaskComment, order_by: [desc: c.id]))
      else
        task
      end

    comment_changeset = TaskComment.changeset(%TaskComment{}, %{})

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:task, task_with_associations)
     |> assign(:column_options, column_options)
     |> assign(:comment_form, to_form(comment_changeset))
     |> assign_form(changeset)}
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
end
