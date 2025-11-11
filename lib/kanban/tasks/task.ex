defmodule Kanban.Tasks.Task do
  use Ecto.Schema
  import Ecto.Changeset

  schema "tasks" do
    field :title, :string
    field :description, :string
    field :position, :integer
    field :type, Ecto.Enum, values: [:work, :defect], default: :work
    field :priority, Ecto.Enum, values: [:low, :medium, :high, :critical], default: :medium

    belongs_to :column, Kanban.Columns.Column

    timestamps()
  end

  @doc false
  def changeset(task, attrs) do
    task
    |> cast(attrs, [:title, :description, :position, :column_id, :type, :priority])
    |> validate_required([:title, :position, :type, :priority])
    |> validate_inclusion(:type, [:work, :defect])
    |> validate_inclusion(:priority, [:low, :medium, :high, :critical])
    |> foreign_key_constraint(:column_id)
    |> unique_constraint([:column_id, :position])
  end
end
