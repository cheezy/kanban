defmodule Kanban.Notifications.ClaimExpiryReport do
  @moduledoc """
  Remembers which expired claims `Kanban.Notifications.ClaimExpiryWorker`
  has already reported, so `[:kanban, :task, :claim_expired]` is emitted once
  per claim.

  A claim is identified by its task id and its `claim_expires_at`. `record/1`
  inserts that pair against a unique index, so of two sweeps that see the
  same claim, even concurrently or after a restart, only one gets `:new`.
  `prune/1` removes rows the sweeper can no longer see.

  Neither function raises: a database error is logged with the task id only
  and treated as already reported, so the sweep carries on and never emits
  twice.
  """

  use Ecto.Schema

  import Ecto.Query, only: [from: 2]

  alias Kanban.Repo
  alias Kanban.Tasks.Task

  require Logger

  schema "claim_expiry_reports" do
    belongs_to :task, Task
    field :claim_expires_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Records that `task`'s current claim expired. Returns `:new` the first time
  a claim is recorded and `:seen` after that.
  """
  @spec record(Task.t()) :: :new | :seen
  def record(%Task{id: task_id, claim_expires_at: %DateTime{} = expires_at}) do
    now = DateTime.utc_now(:second)

    row = %{
      task_id: task_id,
      claim_expires_at: DateTime.truncate(expires_at, :second),
      inserted_at: now
    }

    case Repo.insert_all(__MODULE__, [row],
           on_conflict: :nothing,
           conflict_target: [:task_id, :claim_expires_at]
         ) do
      {1, _} -> :new
      {0, _} -> :seen
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning(
        "claim expiry report failed for task #{task_id}: #{inspect(error.__struct__)}"
      )

      :seen
  end

  def record(%Task{}), do: :seen

  @doc """
  Deletes the reports for claims that expired before `cutoff`. Returns the
  number of rows removed.
  """
  @spec prune(DateTime.t()) :: non_neg_integer()
  def prune(%DateTime{} = cutoff) do
    {count, _} =
      from(r in __MODULE__, where: r.claim_expires_at < ^cutoff)
      |> Repo.delete_all()

    count
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning("claim expiry report prune failed: #{inspect(error.__struct__)}")
      0
  end
end
