defmodule KanbanWeb.ColumnLive.FormComponent do
  use KanbanWeb, :live_component

  alias Kanban.Columns

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        <%= @title %>
        <:subtitle>
          <%= if @action == :new_column do %>
            {gettext("Create a new column for your board")}
          <% else %>
            {gettext("Update column details")}
          <% end %>
        </:subtitle>
      </.header>

      <.form
        :let={f}
        for={@form}
        id="column-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <.input field={f[:name]} type="text" label={gettext("Name")} required />

        <.input
          field={f[:wip_limit]}
          type="number"
          label={gettext("WIP Limit")}
          min="0"
        />
        <p class="mt-1 text-sm text-gray-500">
          {gettext("Work In Progress limit. Set to 0 for no limit.")}
        </p>

        <div class="mt-6 flex items-center gap-4">
          <.button phx-disable-with={gettext("Saving...")}>{gettext("Save Column")}</.button>
        </div>
      </.form>
    </div>
    """
  end

  @impl true
  def update(%{column: column} = assigns, socket) do
    changeset = Columns.Column.changeset(column, %{})

    {:ok,
     socket
     |> assign(assigns)
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("validate", %{"column" => column_params}, socket) do
    changeset =
      socket.assigns.column
      |> Columns.Column.changeset(column_params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"column" => column_params}, socket) do
    save_column(socket, socket.assigns.action, column_params)
  end

  defp save_column(socket, :edit_column, column_params) do
    case Columns.update_column(socket.assigns.column, column_params) do
      {:ok, column} ->
        notify_parent({:saved, column})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Column updated successfully"))
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_column(socket, :new_column, column_params) do
    case Columns.create_column(socket.assigns.board, column_params) do
      {:ok, column} ->
        notify_parent({:saved, column})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Column created successfully"))
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
