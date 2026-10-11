defmodule Kanban.Tasks.TaskTelemetry do
  @moduledoc """
  Emits the task lifecycle telemetry events through `Kanban.Telemetry`.

  Every event here measures `count: 1` and carries the task id in its
  metadata. Ids are labels, not numbers to add up, so they never go in
  measurements. The event names are the legacy names in
  `Kanban.Telemetry.Catalog` and must not change.
  """

  alias Kanban.Tasks.Task

  @doc """
  Emits `[:kanban, :task, :archived]`.

  `extra` adds `via` (`:bulk` or `:goal_cascade`) and, for a cascade, the
  parent `goal_id`.
  """
  @spec archived(Task.t(), map()) :: :ok
  def archived(%Task{} = task, extra \\ %{}) do
    metadata = Map.merge(%{task_id: task.id, identifier: task.identifier}, extra)
    Kanban.Telemetry.emit([:kanban, :task, :archived], %{count: 1}, metadata)
  end

  @doc """
  Emits `[:kanban, :task, :unarchived]`.
  """
  @spec unarchived(Task.t()) :: :ok
  def unarchived(%Task{} = task) do
    Kanban.Telemetry.emit([:kanban, :task, :unarchived], %{count: 1}, %{
      task_id: task.id,
      identifier: task.identifier
    })
  end

  @doc """
  Emits `[:kanban, :task, :completed]` for a task completed by `user_id`.
  """
  @spec completed(Task.t(), integer()) :: :ok
  def completed(%Task{} = task, user_id) do
    Kanban.Telemetry.emit([:kanban, :task, :completed], %{count: 1}, %{
      task_id: task.id,
      completed_by: user_id
    })
  end

  @doc """
  Emits `[:kanban, :task, :moved_to_review]`.

  `time_spent_minutes` is read from the saved task, where the changeset has
  already cast it to an integer. It is measured only when it is an integer, so
  the measurement is never a string or `nil`.
  """
  @spec moved_to_review(Task.t(), integer()) :: :ok
  def moved_to_review(%Task{} = task, user_id) do
    Kanban.Telemetry.emit(
      [:kanban, :task, :moved_to_review],
      review_measurements(task.time_spent_minutes),
      %{task_id: task.id, completed_by_id: user_id}
    )
  end

  @doc """
  Emits `[:kanban, :task, :returned_to_doing]`. `review_status` is the status
  the reviewer set, read before the task was reset.
  """
  @spec returned_to_doing(Task.t(), integer(), atom() | nil) :: :ok
  def returned_to_doing(%Task{} = task, user_id, review_status) do
    Kanban.Telemetry.emit([:kanban, :task, :returned_to_doing], %{count: 1}, %{
      task_id: task.id,
      reviewed_by: user_id,
      review_status: review_status
    })
  end

  defp review_measurements(minutes) when is_integer(minutes),
    do: %{count: 1, time_spent_minutes: minutes}

  defp review_measurements(_minutes), do: %{count: 1}
end
