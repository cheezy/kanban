defmodule Kanban.Tasks.Broadcaster do
  @moduledoc """
  PubSub broadcasting for task changes.

  Broadcasts task events to board-specific PubSub topics so LiveViews
  can react to real-time updates. All broadcast tuples use the
  `Kanban.Tasks` atom to maintain the existing LiveView contract.
  """

  alias Kanban.Repo
  alias Kanban.Tasks.Task

  require Logger

  @doc """
  Broadcasts a task change event to the board's PubSub topic.

  The broadcast tuple uses `Kanban.Tasks` (not this module) to maintain
  compatibility with existing LiveView pattern matches.
  """
  def broadcast_task_change(%Task{} = task, event) do
    task_with_column = Repo.preload(task, [:column, :created_by, :completed_by, :reviewed_by])
    column = task_with_column.column

    if column do
      column_with_board = Repo.preload(column, :board)
      board_id = column_with_board.board.id

      Logger.info("Broadcasting #{event} for task #{task.id} to board:#{board_id}")

      Phoenix.PubSub.broadcast(
        Kanban.PubSub,
        "board:#{board_id}",
        {Kanban.Tasks, event, task_with_column}
      )

      :telemetry.execute(
        [:kanban, :pubsub, :broadcast],
        %{count: 1},
        %{event: event, task_id: task.id, board_id: board_id}
      )
    else
      Logger.warning("Cannot broadcast #{event} for task #{task.id} - no column found")
    end
  end

  @doc """
  Broadcasts a specific event based on changeset changes.

  Inspects the changeset to determine the appropriate event type
  (status change, claim, completion, review, or generic update).
  """
  def broadcast_task_update(%Task{} = task, %Ecto.Changeset{} = changeset) do
    cond do
      Map.has_key?(changeset.changes, :status) ->
        broadcast_task_change(task, :task_status_changed)

      Map.has_key?(changeset.changes, :claimed_at) ->
        broadcast_task_change(task, :task_claimed)

      Map.has_key?(changeset.changes, :completed_at) ->
        broadcast_task_change(task, :task_completed)

      Map.has_key?(changeset.changes, :review_status) ->
        broadcast_task_change(task, :task_reviewed)

      true ->
        broadcast_task_change(task, :task_updated)
    end
  end
end
