defmodule Kanban.Columns.Column do
  use Ecto.Schema
  import Ecto.Changeset

  schema "columns" do
    field :name, :string
    field :position, :integer
    field :wip_limit, :integer, default: 0

    belongs_to :board, Kanban.Boards.Board
    has_many :tasks, Kanban.Tasks.Task

    timestamps()
  end

  @doc false
  def changeset(column, attrs) do
    column
    |> cast(attrs, [:name, :position, :wip_limit, :board_id])
    |> validate_required([:name, :position])
    |> validate_number(:wip_limit, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:board_id)
    |> unique_constraint([:board_id, :position])
  end
end
