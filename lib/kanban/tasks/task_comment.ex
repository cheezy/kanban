defmodule Kanban.Tasks.TaskComment do
  use Ecto.Schema
  import Ecto.Changeset

  schema "task_comments" do
    field :content, :string

    belongs_to :task, Kanban.Tasks.Task

    timestamps()
  end

  @doc """
  D111: `:task_id` is NOT cast from `attrs` — it is set server-side on the struct
  (`%TaskComment{task_id: task.id}`) by the caller. This makes the comment's
  authorship-of-scope structurally un-forgeable: a client-supplied `task_id` can
  never redirect a comment to a task on another board, even if a future caller
  forgets to overwrite it. `validate_required` still asserts the struct carries a
  `task_id`.
  """
  def changeset(task_comment, attrs) do
    task_comment
    |> cast(attrs, [:content])
    |> validate_required([:content, :task_id])
    |> foreign_key_constraint(:task_id)
  end
end
