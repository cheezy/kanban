defmodule KanbanWeb.BoardLive.FormComponent do
  use KanbanWeb, :live_component

  alias Kanban.Boards

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        {@title}
        <:subtitle>Use this form to manage board records in your database.</:subtitle>
      </.header>

      <.form
        :let={f}
        for={@form}
        id="board-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <.input field={f[:name]} type="text" label="Name" />
        <.input field={f[:description]} type="textarea" label="Description" />
        <div class="mt-4">
          <.button phx-disable-with="Saving...">Save Board</.button>
        </div>
      </.form>
    </div>
    """
  end

  @impl true
  def update(%{board: board} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:form, fn ->
       to_form(Boards.change_board(board))
     end)}
  end

  @impl true
  def handle_event("validate", %{"board" => board_params}, socket) do
    changeset = Boards.change_board(socket.assigns.board, board_params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"board" => board_params}, socket) do
    save_board(socket, socket.assigns.action, board_params)
  end

  defp save_board(socket, :edit, board_params) do
    case Boards.update_board(socket.assigns.board, board_params) do
      {:ok, board} ->
        notify_parent({:saved, board})

        {:noreply,
         socket
         |> put_flash(:info, "Board updated successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_board(socket, :new, board_params) do
    case Boards.create_board(socket.assigns.current_user, board_params) do
      {:ok, board} ->
        notify_parent({:saved, board})

        {:noreply,
         socket
         |> put_flash(:info, "Board created successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
