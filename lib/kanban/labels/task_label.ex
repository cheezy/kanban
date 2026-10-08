defmodule Kanban.Labels.TaskLabel do
  @moduledoc """
  Join schema between tasks and labels.

  The `[task_id, label_id]` pair is unique in the database, so concurrent
  edits cannot duplicate a row. Both foreign keys cascade on delete: removing
  a label or a task removes only its join rows.
  """
  use Ecto.Schema

  schema "task_labels" do
    belongs_to :task, Kanban.Tasks.Task
    belongs_to :label, Kanban.Labels.Label

    timestamps()
  end
end
