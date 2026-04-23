defmodule Kanban.Messages.MessageDismissal do
  use Ecto.Schema
  import Ecto.Changeset

  schema "message_dismissals" do
    belongs_to :message, Kanban.Messages.Message
    belongs_to :user, Kanban.Accounts.User

    field :dismissed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(dismissal, attrs) do
    dismissal
    |> cast(attrs, [:message_id, :user_id, :dismissed_at])
    |> put_default_dismissed_at()
    |> validate_required([:message_id, :user_id, :dismissed_at])
    |> foreign_key_constraint(:message_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:message_id, :user_id])
  end

  defp put_default_dismissed_at(changeset) do
    case get_field(changeset, :dismissed_at) do
      nil -> put_change(changeset, :dismissed_at, DateTime.utc_now())
      _ -> changeset
    end
  end
end
