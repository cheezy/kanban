defmodule Kanban.Tasks.TaskComment do
  use Ecto.Schema
  import Ecto.Changeset

  schema "task_comments" do
    field :content, :string

    belongs_to :task, Kanban.Tasks.Task

    timestamps()
  end

  @doc false
  def changeset(task_comment, attrs) do
    task_comment
    |> cast(attrs, [:content, :task_id])
    |> validate_required([:content, :task_id])
    |> foreign_key_constraint(:task_id)
  end
end
