defmodule Kanban.Repo.Migrations.BackfillTaskCreationHistory do
  use Ecto.Migration
  import Ecto.Query

  def up do
    flush()
    populate_creation_history()
  end

  def down do
    # Remove backfilled creation history records
    execute """
    DELETE FROM task_history
    WHERE type = 'creation'
    """
  end

  defp populate_creation_history do
    # Get all tasks that don't have a creation history record
    tasks_without_history =
      from(t in "tasks",
        left_join: h in "task_history",
        on: h.task_id == t.id and h.type == "creation",
        where: is_nil(h.id),
        select: %{id: t.id, inserted_at: t.inserted_at}
      )
      |> repo().all()

    # Create a creation history record for each task
    Enum.each(tasks_without_history, fn task ->
      repo().insert_all("task_history", [
        %{
          type: "creation",
          task_id: task.id,
          from_column: nil,
          to_column: nil,
          inserted_at: task.inserted_at
        }
      ])
    end)
  end
end
