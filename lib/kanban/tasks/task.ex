defmodule Kanban.Tasks.Task do
  use Ecto.Schema
  import Ecto.Changeset

  schema "tasks" do
    field :title, :string
    field :description, :string
    field :position, :integer

    belongs_to :column, Kanban.Columns.Column

    timestamps()
  end

  @doc false
  def changeset(task, attrs) do
    task
    |> cast(attrs, [:title, :description, :position, :column_id])
    |> validate_required([:title, :position])
    |> foreign_key_constraint(:column_id)
    |> unique_constraint([:column_id, :position])
  end
end
