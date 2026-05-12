defmodule KanbanWeb.Admin.MessageLive.Index do
  use KanbanWeb, :live_view

  # Defense-in-depth: the router's `live_session :admin` already declares
  # `{KanbanWeb.UserAuth, :require_admin}` for this route, but we re-declare it
  # here so the LiveView itself cannot be reached by a non-admin even if the
  # route is ever re-grouped or the on_mount hook is dropped from the
  # live_session declaration. Per-event admin? guards below add a third layer.
  on_mount {KanbanWeb.UserAuth, :require_admin}

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
    if admin?(socket) do
      changeset = Messages.change_message(%Message{}, params)
      {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
    else
      halt_non_admin(socket)
    end
  end

  @impl true
  def handle_event("save", %{"message" => params}, socket) do
    if admin?(socket) do
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
    else
      halt_non_admin(socket)
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    if admin?(socket) do
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
    else
      halt_non_admin(socket)
    end
  end

  # Per-event defense-in-depth: even with on_mount enforcement, this guard
  # ensures that no event handler ever mutates state for a non-admin caller.
  defp admin?(socket) do
    case socket.assigns[:current_scope] do
      %{user: %{type: :admin}} -> true
      _ -> false
    end
  end

  defp halt_non_admin(socket) do
    {:noreply, put_flash(socket, :error, gettext("You must be an admin to perform this action."))}
  end

  # Defensive id parser — accepts string ids from phx-value-id attributes,
  # integers from internal callers, and returns nil for anything malformed
  # (non-integer string, non-binary non-integer, etc.) so the LiveView does
  # not crash on a tampered payload. Exposed via @doc false so the regression
  # tests can exercise each head directly.
  @doc false
  def fetch_message(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> Repo.get(Message, int_id)
      _ -> nil
    end
  end

  def fetch_message(id) when is_integer(id), do: Repo.get(Message, id)
  def fetch_message(_), do: nil

  defp assign_new_form(socket) do
    assign(socket, :form, to_form(Messages.change_message(%Message{})))
  end
end
