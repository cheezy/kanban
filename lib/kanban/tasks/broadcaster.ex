defmodule Kanban.Tasks.Broadcaster do
  @moduledoc """
  PubSub broadcasting for task changes.

  Broadcasts task events to board-specific PubSub topics so LiveViews
  can react to real-time updates. All broadcast tuples use the
  `Kanban.Tasks` atom to maintain the existing LiveView contract.
  """

  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias Kanban.Webhooks.Events

  require Logger

  @doc """
  Broadcasts a task change event to the board's PubSub topic.

  The broadcast tuple uses `Kanban.Tasks` (not this module) to maintain
  compatibility with existing LiveView pattern matches.

  It also emits the matching webhook event (`emit_webhook/4`) unless
  `opts[:webhook]` is `false`: bulk actions pass it because they emit per
  task themselves, single label edits (`Kanban.Labels`) because labels are
  not in the payload, and goal repositioning because it can run inside the
  moving task's transaction.
  """
  def broadcast_task_change(%Task{} = task, event, opts \\ []) do
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

      broadcast_agent_event(task_with_column, event, board_id)
      emit_webhook(task_with_column, event, board_id, opts)

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
  Emits the webhook event for a task change (`Kanban.Webhooks.Events`)
  unless `opts[:webhook]` is `false`. Besides `broadcast_task_change/3`, the
  callers are the direct broadcasts in `Kanban.Tasks.AgentWorkflow`, review
  decisions in `Kanban.Reviews` and `Kanban.Tasks.BulkActions`; the changes
  that emit nothing are listed in the `Kanban.Webhooks.Events` moduledoc.
  Call it after the change has committed. Never raises.
  """
  def emit_webhook(%Task{} = task, event, board_id, opts \\ []) do
    if Keyword.get(opts, :webhook, true), do: Events.emit(board_id, event, task), else: :ok
  end

  @doc """
  Broadcasts an agent-surface event to the board-scoped `"agents:\#{board_id}"`
  PubSub topic.

  Maps the task `event` atom to the agent-feed `kind` and emits
  `{:agent_event, payload}` so AgentsLive refreshes live — but only for viewers
  scoped to `board_id`. Each `/agents` viewer subscribes to `"agents:\#{id}"` for
  every board they can access, so a task change on one board no longer redrives
  the heavy /agents load for every viewer of every other board (D125 — the
  previous single global `"agents"` topic broadcast to all viewers on every task
  change across all boards). Completion paths that broadcast only to the board
  topic call this directly to also notify the agents feed, without
  re-broadcasting to the board.
  """
  def broadcast_agent_event(%Task{} = task, event, board_id) do
    case agent_event_kind(event) do
      nil ->
        :ok

      kind ->
        payload = %{
          kind: kind,
          task_id: task.id,
          board_id: board_id,
          agent_name: agent_actor(task, kind),
          at: timestamp_for(task, kind)
        }

        Phoenix.PubSub.broadcast(Kanban.PubSub, "agents:#{board_id}", {:agent_event, payload})
    end
  end

  defp agent_event_kind(:task_created), do: :create
  defp agent_event_kind(:task_claimed), do: :claim
  defp agent_event_kind(:task_completed), do: :complete
  defp agent_event_kind(:task_reviewed), do: :review
  defp agent_event_kind(_), do: nil

  defp agent_actor(task, :complete), do: task.completed_by_agent
  # Review events reuse `completed_by_agent` because the agent surface tracks
  # AI actors; the human reviewer lives on `reviewed_by_id` and is rendered
  # elsewhere.
  defp agent_actor(task, :review), do: task.completed_by_agent
  defp agent_actor(task, _), do: task.created_by_agent

  defp timestamp_for(task, :claim), do: task.claimed_at || DateTime.utc_now()
  defp timestamp_for(task, :complete), do: task.completed_at || DateTime.utc_now()
  defp timestamp_for(task, :review), do: task.reviewed_at || DateTime.utc_now()

  defp timestamp_for(%{inserted_at: %NaiveDateTime{} = ndt}, :create) do
    DateTime.from_naive!(ndt, "Etc/UTC")
  end

  defp timestamp_for(_task, _kind), do: DateTime.utc_now()

  @doc """
  Broadcasts a specific event based on changeset changes.

  Inspects the changeset to determine the appropriate event type
  (status change, claim, completion, review, or generic update).
  """
  def broadcast_task_update(%Task{} = task, %Ecto.Changeset{} = changeset) do
    broadcast_task_change(task, classify_task_update_event(changeset))
  end

  defp classify_task_update_event(changeset) do
    cond do
      Map.has_key?(changeset.changes, :status) -> :task_status_changed
      Map.has_key?(changeset.changes, :claimed_at) -> :task_claimed
      Map.has_key?(changeset.changes, :completed_at) -> :task_completed
      Map.has_key?(changeset.changes, :review_status) -> :task_reviewed
      true -> :task_updated
    end
  end
end
