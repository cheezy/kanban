defmodule KanbanWeb.Admin.MessageLive.Index do
  use KanbanWeb, :live_view

  alias Kanban.Messages
  alias Kanban.Messages.Message
  alias Kanban.Repo

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Broadcast Messages"))
     |> assign(:messages, Messages.list_messages())
     |> assign_new_form()}
  end

  @impl true
  def handle_event("validate", %{"message" => params}, socket) do
    changeset = Messages.change_message(%Message{}, params)
    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  @impl true
  def handle_event("save", %{"message" => params}, socket) do
    user = socket.assigns.current_scope.user

    case Messages.create_message(user, params) do
      {:ok, _message} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Message created."))
         |> assign(:messages, Messages.list_messages())
         |> assign_new_form()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    case fetch_message(id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Message not found."))}

      message ->
        {:ok, _} = Messages.delete_message(message)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Message deleted."))
         |> assign(:messages, Messages.list_messages())}
    end
  end

  defp fetch_message(id) do
    id
    |> String.to_integer()
    |> then(&Repo.get(Message, &1))
  end

  defp assign_new_form(socket) do
    assign(socket, :form, to_form(Messages.change_message(%Message{})))
  end
end
