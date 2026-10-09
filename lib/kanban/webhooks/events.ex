defmodule Kanban.Webhooks.Events do
  @moduledoc """
  Turns task changes into webhook deliveries (W2227).

  `emit/3` maps an internal event atom to its public name, finds the
  board's enabled endpoints subscribed to it, builds the envelope once
  (`Kanban.Webhooks.Payload`) and queues one `Kanban.Webhooks.DeliveryWorker`
  job per endpoint. A board with no subscribed endpoint costs one indexed
  query and builds nothing.

  | Internal atom | Public event |
  |---|---|
  | `:task_created` | `task.created` |
  | `:task_updated`, `:task_status_changed` | `task.updated` |
  | `:task_moved`, `:task_returned_to_doing` | `task.moved` |
  | `:task_claimed` | `task.claimed` |
  | `:task_unclaimed` | `task.unclaimed` |
  | `:task_completed` | `task.completed` |
  | `:task_moved_to_review` | `task.moved_to_review` |
  | `:task_reviewed` | `task.reviewed` |
  | `:task_deleted` | `task.deleted` |

  Any other atom emits nothing.

  It is called only through `Kanban.Tasks.Broadcaster.emit_webhook/4`: from
  `broadcast_task_change/3`, from the direct broadcasts in
  `Kanban.Tasks.AgentWorkflow` (claim, unclaim, move to review, completion,
  return to Doing), from `Kanban.Reviews` (review decisions, plus the
  completion an approval causes) and from `Kanban.Tasks.BulkActions` (one
  event per changed task). Each change is emitted from one of them only, so
  it yields one event, and always after the change has committed.

  These changes emit nothing: rows removed by a database cascade,
  dependency status flips, label changes (labels are not in the payload),
  and a goal's automatic repositioning when one of its children moves (it
  can run inside the child's transaction; the child's own event is sent).
  A goal moved to Done by its after_goal report, or promoted to Ready, does
  emit `task.moved`.

  Should a caller ever emit inside a transaction, the job insert joins it, so
  a rollback removes the job. It never raises into the caller; a failure is
  logged with ids only.
  """

  import Ecto.Query, only: [where: 3, order_by: 3, select: 3]

  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias Kanban.Webhooks.DeliveryWorker
  alias Kanban.Webhooks.Endpoint
  alias Kanban.Webhooks.Payload

  require Logger

  @public_names %{
    task_created: "task.created",
    task_updated: "task.updated",
    task_status_changed: "task.updated",
    task_moved: "task.moved",
    task_returned_to_doing: "task.moved",
    task_claimed: "task.claimed",
    task_unclaimed: "task.unclaimed",
    task_completed: "task.completed",
    task_moved_to_review: "task.moved_to_review",
    task_reviewed: "task.reviewed",
    task_deleted: "task.deleted"
  }

  @doc "The public event name for an internal event atom, or `nil`."
  @spec public_name(atom()) :: String.t() | nil
  def public_name(event), do: Map.get(@public_names, event)

  @doc """
  Queues deliveries of `event` about `task` to the board's subscribed
  endpoints. Always returns `:ok`.
  """
  @spec emit(integer() | nil, atom(), Task.t()) :: :ok
  def emit(board_id, event, %Task{} = task) do
    safely(event, task, fn -> event |> public_name() |> deliver(board_id, task) end)
  end

  defp deliver(nil, _board_id, _task), do: :ok

  defp deliver(name, board_id, task) do
    with [_ | _] = endpoint_ids <- subscribed_endpoint_ids(board_id, name),
         {:ok, payload} <- Payload.build(name, task) do
      DeliveryWorker.enqueue_all(endpoint_ids, name, payload)
    end
  end

  # Only ids are selected, so no URL is decrypted on this hot path.
  defp subscribed_endpoint_ids(nil, _name), do: []

  defp subscribed_endpoint_ids(board_id, name) do
    Endpoint
    |> where([e], e.board_id == ^board_id and e.enabled and ^name in e.event_types)
    |> order_by([e], asc: e.id)
    |> select([e], e.id)
    |> Repo.all()
  end

  defp safely(event, task, fun) do
    fun.()
    :ok
  rescue
    exception ->
      Logger.warning(
        "webhook event #{inspect(event)} not emitted for task #{task.id}: " <>
          inspect(exception.__struct__)
      )

      :ok
  end
end
