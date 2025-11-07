defmodule KanbanWeb.TaskLive.FormComponent do
  use KanbanWeb, :live_component

  alias Kanban.Columns
  alias Kanban.Tasks

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        <%= @title %>
        <:subtitle>
          <%= if @action == :new_task do %>
            {gettext("Create a new task")}
          <% else %>
            {gettext("Update task details")}
          <% end %>
        </:subtitle>
      </.header>

      <.form
        :let={f}
        for={@form}
        id="task-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <.input field={f[:title]} type="text" label={gettext("Title")} required />

        <.input
          field={f[:description]}
          type="textarea"
          label={gettext("Description")}
          rows="4"
        />

        <%= if @action == :new_task do %>
          <.input
            field={f[:column_id]}
            type="select"
            label={gettext("Column")}
            options={@column_options}
            required
          />
        <% end %>

        <div class="mt-6 flex items-center gap-4">
          <.button phx-disable-with={gettext("Saving...")}>{gettext("Save Task")}</.button>
        </div>
      </.form>
    </div>
    """
  end

  @impl true
  def update(%{task: task, board: board} = assigns, socket) do
    columns = Columns.list_columns(board)
    column_id = get_column_id(assigns, task)
    changeset = build_changeset(task, column_id)
    column_options = build_column_options(columns, task)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:column_options, column_options)
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
