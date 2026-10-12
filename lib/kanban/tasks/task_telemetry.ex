defmodule Kanban.Tasks.TaskTelemetry do
  @moduledoc """
  Emits the task lifecycle telemetry events through `Kanban.Telemetry`.

  Every event here measures `count: 1` and carries the task id in its
  metadata. Ids are labels, not numbers to add up, so they never go in
  measurements. The legacy event names in `Kanban.Telemetry.Catalog` must not
  change.

  The task activity events (`updated`, `moved`, `reordered`, `deleted`,
  `claimed`, `unclaimed`, `claim_expired`, the two review decisions and
  `comment_created`) are declared in `Kanban.Telemetry.Catalog.TaskEvents`.
  Each is emitted only after its change has been saved, so a refused, invalid
  or rolled-back change emits nothing. The functions that take a result
  return it unchanged, so they can sit at the end of a pipe without changing
  what the caller sees. Metadata carries ids, atoms, booleans and field names
  only, never a task's text, a comment body, review notes or an unclaim
  reason.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias Kanban.Columns.Column
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskComment

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

  @doc """
  Emits `[:kanban, :task, :updated]` when `result` is a saved task and the
  changeset changed at least one field. `fields` lists the changed field
  names, never their values. `source` is `:ui` or `:api`, and `actor` is the
  user who made the change, or `nil` when it is not known. Returns `result`.
  """
  @spec updated(result, Changeset.t(), :ui | :api, %{id: integer()} | nil) :: result
        when result: term()
  def updated({:ok, %Task{} = task} = result, %Changeset{changes: changes}, source, actor)
      when map_size(changes) > 0 do
    Kanban.Telemetry.emit([:kanban, :task, :updated], %{count: 1}, %{
      task_id: task.id,
      board_id: board_id(task),
      fields: changes |> Map.keys() |> Enum.sort(),
      source: source,
      actor_user_id: actor_id(actor)
    })

    result
  end

  def updated(result, _changeset, _source, _actor), do: result

  @doc """
  Emits `[:kanban, :task, :moved]` for a saved move from `from_column_id` to
  another column, or `[:kanban, :task, :reordered]` when the task stayed in
  `from_column_id`.
  """
  @spec moved(Task.t(), integer(), integer()) :: :ok
  def moved(%Task{column_id: column_id} = task, column_id, board_id) do
    Kanban.Telemetry.emit([:kanban, :task, :reordered], %{count: 1}, %{
      task_id: task.id,
      column_id: column_id,
      board_id: board_id
    })
  end

  def moved(%Task{} = task, from_column_id, board_id) do
    Kanban.Telemetry.emit([:kanban, :task, :moved], %{count: 1}, %{
      task_id: task.id,
      board_id: board_id,
      from_column_id: from_column_id,
      to_column_id: task.column_id
    })
  end

  @doc """
  Emits `[:kanban, :task, :reordered]` for a committed reorder of `column`.
  `task_count` is the number of task ids given. Returns `result`.
  """
  @spec column_reordered(result, Column.t(), list()) :: result when result: term()
  def column_reordered({:ok, _} = result, %Column{} = column, task_ids) when is_list(task_ids) do
    Kanban.Telemetry.emit(
      [:kanban, :task, :reordered],
      %{count: 1, task_count: length(task_ids)},
      %{column_id: column.id, board_id: column.board_id}
    )

    result
  end

  def column_reordered(result, _column, _task_ids), do: result

  @doc """
  Emits `[:kanban, :task, :deleted]` for a deleted task.
  """
  @spec deleted(Task.t()) :: :ok
  def deleted(%Task{} = task) do
    Kanban.Telemetry.emit([:kanban, :task, :deleted], %{count: 1}, %{
      task_id: task.id,
      board_id: board_id(task)
    })
  end

  @doc """
  Emits `[:kanban, :task, :claimed]` when `result` is a successful claim by
  `user_id`. Returns `result`.
  """
  @spec claimed(result, integer(), integer()) :: result when result: term()
  def claimed({:ok, %Task{} = task, _hook_info} = result, user_id, board_id) do
    Kanban.Telemetry.emit([:kanban, :task, :claimed], %{count: 1}, %{
      task_id: task.id,
      board_id: board_id,
      user_id: user_id
    })

    result
  end

  def claimed(result, _user_id, _board_id), do: result

  @doc """
  Emits `[:kanban, :task, :unclaimed]`. `has_reason` says whether the user
  gave a reason; the reason itself is never passed here.
  """
  @spec unclaimed(Task.t(), integer(), integer(), boolean()) :: :ok
  def unclaimed(%Task{} = task, user_id, board_id, has_reason) when is_boolean(has_reason) do
    Kanban.Telemetry.emit([:kanban, :task, :unclaimed], %{count: 1}, %{
      task_id: task.id,
      board_id: board_id,
      user_id: user_id,
      has_reason: has_reason
    })
  end

  @doc """
  Emits `[:kanban, :task, :claim_expired]` for a task whose claim expired.
  `user_id` is the assignee whose claim it was.
  """
  @spec claim_expired(Task.t()) :: :ok
  def claim_expired(%Task{} = task) do
    Kanban.Telemetry.emit([:kanban, :task, :claim_expired], %{count: 1}, %{
      task_id: task.id,
      board_id: board_id(task),
      user_id: task.assigned_to_id
    })
  end

  @doc """
  Emits `[:kanban, :task, :review_approved]` or
  `[:kanban, :task, :review_changes_requested]` when `result` is a committed
  review by `reviewer`. The review notes are never sent. Returns `result`.
  """
  @spec reviewed(result, :approved | :changes_requested, %{id: integer()}) :: result
        when result: term()
  def reviewed({:ok, %Task{} = task} = result, :approved, reviewer) do
    Kanban.Telemetry.emit([:kanban, :task, :review_approved], %{count: 1}, %{
      task_id: task.id,
      board_id: board_id(task),
      reviewer_user_id: reviewer.id
    })

    result
  end

  def reviewed({:ok, %Task{} = task} = result, :changes_requested, reviewer) do
    Kanban.Telemetry.emit([:kanban, :task, :review_changes_requested], %{count: 1}, %{
      task_id: task.id,
      board_id: board_id(task),
      reviewer_user_id: reviewer.id
    })

    result
  end

  def reviewed(result, _decision, _reviewer), do: result

  @doc """
  Emits `[:kanban, :task, :comment_created]` when `result` is a saved
  comment on a task of `board_id`. The comment text is never sent. Returns
  `result`.
  """
  @spec comment_created(result, integer()) :: result when result: term()
  def comment_created({:ok, %TaskComment{} = comment} = result, board_id) do
    Kanban.Telemetry.emit([:kanban, :task, :comment_created], %{count: 1}, %{
      task_id: comment.task_id,
      board_id: board_id,
      comment_id: comment.id,
      user_id: comment.author_user_id,
      by_agent: not is_nil(comment.author_agent_name)
    })

    result
  end

  def comment_created(result, _board_id), do: result

  # The board id comes from the preloaded column when there is one, otherwise
  # from the task's column row. A failed lookup sends nil rather than raising
  # into the write that is being reported.
  defp board_id(%Task{column: %Column{board_id: board_id}}), do: board_id
  defp board_id(%Task{column_id: nil}), do: nil

  defp board_id(%Task{column_id: column_id}) do
    from(c in Column, where: c.id == ^column_id, select: c.board_id)
    |> Repo.one()
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> nil
  end

  defp actor_id(%{id: id}), do: id
  defp actor_id(_actor), do: nil

  defp review_measurements(minutes) when is_integer(minutes),
    do: %{count: 1, time_spent_minutes: minutes}

  defp review_measurements(_minutes), do: %{count: 1}
end
