defmodule Kanban.Repo.Migrations.AddIdentifierToTasks do
  use Ecto.Migration

  import Ecto.Query

  def up do
    alter table(:tasks) do
      add :identifier, :string
    end

    # Populate identifiers for existing tasks
    flush()
    populate_identifiers()

    create unique_index(:tasks, [:identifier])
  end

  def down do
    drop index(:tasks, [:identifier])

    alter table(:tasks) do
      remove :identifier
    end
  end

  defp populate_identifiers do
    # Get all boards
    boards =
      from(b in "boards", select: %{id: b.id})
      |> repo().all()

    # For each board, populate identifiers for tasks by type
    Enum.each(boards, fn board ->
      populate_board_identifiers(board.id)
    end)
  end

  defp populate_board_identifiers(board_id) do
    # Get all tasks for this board, ordered by creation date
    # Join through columns to get board_id
    tasks =
      from(t in "tasks",
        join: c in "columns",
        on: t.column_id == c.id,
        where: c.board_id == ^board_id,
        select: %{id: t.id, type: t.type, inserted_at: t.inserted_at},
        order_by: [asc: t.inserted_at]
      )
      |> repo().all()

    # Group by type and assign sequential identifiers
    tasks
    |> Enum.group_by(& &1.type)
    |> Enum.each(fn {type, type_tasks} ->
      prefix = if type == "work", do: "W", else: "D"

      type_tasks
      |> Enum.with_index(1)
      |> Enum.each(fn {task, index} ->
        identifier = "#{prefix}#{index}"

        from(t in "tasks", where: t.id == ^task.id)
        |> repo().update_all(set: [identifier: identifier])
      end)
    end)
  end
end
