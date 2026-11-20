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
  Records the move of `task` from the column `from` to the column `to`, as
  `create_move_history/3` does, when they are different columns. The agent
  workflow calls it for every column move it makes, inside the move's
  transaction: a claim and an unclaim (`Kanban.Tasks.AgentWorkflow.Claiming`),
  a completion to Review and its auto-move to Done
  (`Kanban.Tasks.AgentWorkflow.Completion`), an approved, changes-requested
  or rejected review and `mark_done` (`Kanban.Tasks.AgentWorkflow.Review`),
  and a claim release (`Kanban.Tasks.ClaimRelease`). A task that stays in its
  column records nothing and answers `nil`.

  Metrics read move rows only on regular boards (`Kanban.Metrics`,
  `Kanban.Metrics.TaskQueries`), and the agent workflow runs only on
  AI-optimized boards, so these rows never reach a metric.
  """
  @spec record_move(map(), map(), map()) :: Ecto.Schema.t() | nil
  def record_move(_task, %{id: id}, %{id: id}), do: nil

  def record_move(task, %{name: from_name}, %{name: to_name}),
    do: create_move_history(task, from_name, to_name)

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
  Each task's latest `:move` row, as a map of task id to `%{at: at,
  to_column: name}`: the row's naive UTC insert time and the name of the
  column it moved the task to. The latest is the newest `inserted_at`, the
  higher id on a tie. One query. A task with no move row has no key. `[]`
  makes no query.
  """
  @spec latest_move_by_task([integer()]) :: %{
          integer() => %{at: NaiveDateTime.t(), to_column: String.t() | nil}
        }
  def latest_move_by_task([]), do: %{}

  def latest_move_by_task(task_ids) when is_list(task_ids) do
    from(h in TaskHistory,
      where: h.type == :move and h.task_id in ^task_ids,
      distinct: h.task_id,
      order_by: [asc: h.task_id, desc: h.inserted_at, desc: h.id],
      select: {h.task_id, %{at: h.inserted_at, to_column: h.to_column}}
    )
    |> Repo.all()
    |> Map.new()
  end
end
