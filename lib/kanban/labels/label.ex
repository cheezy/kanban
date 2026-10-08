defmodule Kanban.Labels.Label do
  @moduledoc """
  A board-scoped label that can be attached to tasks.

  `color` is an `Ecto.Enum` of fixed token names rather than a free-form
  string, so a label's colour can only ever map to a theme-aware design token
  and never carry arbitrary CSS. `board_id` is set on the struct by
  `Kanban.Labels` and is never cast, so a label cannot be moved between boards
  through its attributes.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @colors [:gray, :red, :orange, :yellow, :green, :teal, :blue, :purple, :pink]
  @max_name_length 40

  schema "labels" do
    belongs_to :board, Kanban.Boards.Board

    field :name, :string
    field :color, Ecto.Enum, values: @colors

    many_to_many :tasks, Kanban.Tasks.Task, join_through: Kanban.Labels.TaskLabel

    timestamps()
  end

  @doc """
  Builds a changeset for a label.

  The name is trimmed before the length and uniqueness checks, and its length
  is counted in codepoints to match the `varchar(40)` column. Uniqueness is
  case-insensitive per board, enforced by the `lower(name)` expression index.
  """
  def changeset(label, attrs) do
    label
    |> cast(attrs, [:name, :color])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :color])
    |> validate_length(:name, max: @max_name_length, count: :codepoints)
    |> unique_constraint(:name, name: :labels_board_id_lower_name_index)
  end

  @doc "The fixed list of colour token names a label may use."
  def colors, do: @colors
end
