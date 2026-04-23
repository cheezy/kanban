defmodule Kanban.Messages.Message do
  use Ecto.Schema
  import Ecto.Changeset

  schema "messages" do
    field :title, :string
    field :body, :string

    belongs_to :sender, Kanban.Accounts.User
    has_many :dismissals, Kanban.Messages.MessageDismissal

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:title, :body, :sender_id])
    |> validate_required([:title, :body])
    |> foreign_key_constraint(:sender_id)
  end
end
