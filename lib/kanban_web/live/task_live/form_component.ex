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

        <.input
          field={f[:type]}
          type="select"
          label={gettext("Type")}
          options={[{gettext("Work"), :work}, {gettext("Defect"), :defect}]}
          required
        />

        <.input
          field={f[:priority]}
          type="select"
          label={gettext("Priority")}
          options={[
            {gettext("Low"), :low},
            {gettext("Medium"), :medium},
            {gettext("High"), :high},
            {gettext("Critical"), :critical}
          ]}
          required
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

      <%= if @action == :edit_task && @task.id && length(@task.task_histories || []) > 0 do %>
        <div class="mt-8 pt-8 border-t border-gray-200">
          <h3 class="text-lg font-semibold text-gray-900 mb-4">{gettext("Task History")}</h3>
          <div class="space-y-3">
            <%= for history <- @task.task_histories do %>
              <div class="flex items-start gap-3 text-sm">
                <div class="flex-shrink-0 mt-0.5">
                  <%= if history.type == :creation do %>
                    <.icon name="hero-plus-circle" class="h-5 w-5 text-green-500" />
                  <% else %>
                    <.icon name="hero-arrow-right-circle" class="h-5 w-5 text-blue-500" />
                  <% end %>
                </div>
                <div class="flex-1">
                  <%= if history.type == :creation do %>
                    <p class="text-gray-900">
                      <span class="font-medium">{gettext("Created")}</span>
                    </p>
                  <% else %>
                    <p class="text-gray-900">
                      <span class="font-medium">{gettext("Moved")}</span>
                      {gettext("from")}
                      <span class="font-medium text-blue-600"><%= history.from_column %></span>
                      {gettext("to")}
                      <span class="font-medium text-blue-600"><%= history.to_column %></span>
                    </p>
                  <% end %>
                  <p class="text-xs text-gray-500 mt-0.5">
                    <%= Calendar.strftime(history.inserted_at, "%B %d, %Y at %I:%M %p") %>
                  </p>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  @impl true
  def update(%{task: task, board: board, action: action} = assigns, socket) do
    columns = Columns.list_columns(board)
    column_id = get_column_id(assigns, task)
    changeset = build_changeset(task, column_id)
    column_options = build_column_options(columns, task)

    # Preload task histories when editing
    task_with_history =
      if action == :edit_task && task.id do
        Tasks.get_task_with_history!(task.id)
      else
        task
      end

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:task, task_with_history)
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
