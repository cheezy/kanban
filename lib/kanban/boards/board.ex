defmodule Kanban.Boards.Board do
  use Ecto.Schema
  import Ecto.Changeset

  schema "boards" do
    field :name, :string
    field :description, :string

    has_many :board_users, Kanban.Boards.BoardUser
    has_many :columns, Kanban.Columns.Column
    many_to_many :users, Kanban.Accounts.User, join_through: Kanban.Boards.BoardUser

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
