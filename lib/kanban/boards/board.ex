defmodule Kanban.Boards.Board do
  use Ecto.Schema
  import Ecto.Changeset

  schema "boards" do
    field :name, :string
    field :description, :string

    belongs_to :user, Kanban.Accounts.User

    timestamps()
  end

  @doc false
  def changeset(board, attrs) do
    board
    |> cast(attrs, [:name, :description])
    |> validate_required([:name])
    |> validate_length(:name, min: 5, max: 50)
    |> validate_length(:description, max: 255)
  end
end
