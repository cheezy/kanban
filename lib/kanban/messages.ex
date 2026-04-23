defmodule Kanban.Messages do
  @moduledoc """
  The Messages context.

  Exposes the surface area the admin LiveView and board show LiveView need
  for admin-authored broadcast messages: create, delete, list for admin,
  list undismissed for a given user, and record a per-user dismissal.
  """

  use Gettext, backend: KanbanWeb.Gettext
  import Ecto.Query, warn: false

  alias Kanban.Repo

  alias Kanban.Messages.Message
  alias Kanban.Messages.MessageDismissal

  @doc """
  Returns the list of messages for the admin view, newest first.

  ## Examples

      iex> list_messages()
      [%Message{}, ...]

  """
  def list_messages do
    Message
    |> order_by([m], desc: m.inserted_at)
    |> Repo.all()
  end

  @doc """
  Creates a message authored by the given sender user.

  ## Examples

      iex> create_message(user, %{title: "hi", body: "there"})
      {:ok, %Message{}}

      iex> create_message(user, %{title: nil})
      {:error, %Ecto.Changeset{}}

  """
  def create_message(%{id: sender_id}, attrs) do
    %Message{sender_id: sender_id}
    |> Message.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Deletes the given message.

  Cascades to all associated dismissals via the database foreign key.
  """
  def delete_message(%Message{} = message) do
    Repo.delete(message)
  end

  @doc """
  Returns messages the given user has NOT yet dismissed, newest first.

  ## Examples

      iex> list_undismissed_for_user(user)
      [%Message{}, ...]

  """
  def list_undismissed_for_user(%{id: user_id}) do
    Message
    |> join(:left, [m], d in MessageDismissal, on: d.message_id == m.id and d.user_id == ^user_id)
    |> where([_m, d], is_nil(d.id))
    |> order_by([m], desc: m.inserted_at)
    |> Repo.all()
  end

  @doc """
  Records a dismissal of `message_id` by `user`.

  Idempotent — calling twice with the same (user, message) does not raise
  and does not create duplicate rows. Relies on the unique index on
  `(message_id, user_id)` in the `message_dismissals` table.

  Returns `{:error, changeset}` if the given `message_id` does not exist.
  """
  def dismiss_message(%{id: user_id}, message_id) do
    attrs = %{message_id: message_id, user_id: user_id}

    %MessageDismissal{}
    |> MessageDismissal.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:message_id, :user_id])
  end

  @doc """
  Returns a changeset for the given message and attrs, useful for tracking
  form changes in a LiveView.
  """
  def change_message(%Message{} = message, attrs \\ %{}) do
    Message.changeset(message, attrs)
  end
end
