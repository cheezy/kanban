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
    # :sender_id is intentionally NOT cast — authorship is set server-side from
    # the authenticated user in Messages.create_message/2 (%Message{sender_id: ...}),
    # never from request params. Casting it would let an admin forge a broadcast
    # message's author via message[sender_id] (D94). The foreign_key_constraint
    # below still guards DB-level integrity.
    message
    |> cast(attrs, [:title, :body])
    |> validate_required([:title, :body])
    |> foreign_key_constraint(:sender_id)
  end
end
