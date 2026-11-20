defmodule Kanban.Tasks.History do
  @moduledoc """
  Task history records for tracking moves, priority changes, and assignments.
  """

  import Ecto.Query, warn: false

  alias Kanban.Repo
  alias Kanban.Tasks.TaskHistory

  @doc """
  Records a task move from one column to another.
  """
  def create_move_history(task, from_column_name, to_column_name) do
    %TaskHistory{}
    |> TaskHistory.changeset(%{
      task_id: task.id,
      type: :move,
      from_column: from_column_name,
      to_column: to_column_name
    })
    |> Repo.insert!()
  end

  @doc """
  Records a priority change on a task.
  """
  def create_priority_change_history(from_priority, to_priority, task_id) do
    %TaskHistory{}
    |> TaskHistory.changeset(%{
      task_id: task_id,
      type: :priority_change,
      from_priority: Atom.to_string(from_priority),
      to_priority: Atom.to_string(to_priority)
    })
    |> Repo.insert!()
  end

  @doc """
  Records an assignment change on a task.
  """
  def create_assignment_history(from_user_id, to_user_id, task_id) do
    %TaskHistory{}
    |> TaskHistory.changeset(%{
      task_id: task_id,
      type: :assignment,
      from_user_id: from_user_id,
      to_user_id: to_user_id
    })
    |> Repo.insert!()
  end

  @doc """
  The time of each task's latest `:move` row, as a map of task id to naive
  UTC time, in one query. A task with no move row has no key. `[]` makes no
  query.
  """
  @spec latest_move_at_by_task([integer()]) :: %{integer() => NaiveDateTime.t()}
  def latest_move_at_by_task([]), do: %{}

  def latest_move_at_by_task(task_ids) when is_list(task_ids) do
    from(h in TaskHistory,
      where: h.type == :move and h.task_id in ^task_ids,
      group_by: h.task_id,
      select: {h.task_id, max(h.inserted_at)}
    )
    |> Repo.all()
    |> Map.new()
  end
end
