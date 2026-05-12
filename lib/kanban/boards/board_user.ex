defmodule Kanban.Boards.BoardUser do
  use Ecto.Schema
  import Ecto.Changeset

  @access_levels [:owner, :read_only, :modify]

  schema "board_users" do
    belongs_to :board, Kanban.Boards.Board
    belongs_to :user, Kanban.Accounts.User

    field :access, Ecto.Enum, values: @access_levels

    timestamps()
  end

  @doc false
  def changeset(board_user, attrs) do
    board_user
    |> cast(attrs, [:board_id, :user_id, :access])
    |> validate_required([:board_id, :user_id, :access])
    |> validate_inclusion(:access, @access_levels)
    |> unique_constraint([:board_id, :user_id])
    |> unique_constraint(:board_id,
      name: :board_users_one_owner_per_board,
      message: "board already has an owner"
    )
  end

  def access_levels, do: @access_levels
end
