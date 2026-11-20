defmodule Kanban.Tasks.TaskClaim do
  @moduledoc """
  The claim history of a task: one row per agent claim, holding the task and
  the moment it was claimed, to the microsecond.

  A task's own claim fields describe only its current claim: an unclaim or a
  released claim (`Kanban.Tasks.ClaimRelease`) clears `claimed_at`, and a
  claim writes no `task_history` row. This table keeps every claim, so
  "was this task claimed after this moment?" has an answer after the claim
  has ended. `Kanban.Decisions.Sources` asks it to clear a released decision
  once the task is claimed again, however that claim ends.

  `Kanban.Tasks.AgentWorkflow` claiming is the only claim writer, and it
  records the row inside its claim transaction (`record/2`). Rows carry no
  user and are deleted with their task.
  """

  use Ecto.Schema

  import Ecto.Query, only: [from: 2]

  alias Kanban.Repo
  alias Kanban.Tasks.Task

  schema "task_claims" do
    belongs_to :task, Task
    field :claimed_at, :utc_datetime_usec
  end

  @doc """
  Records that the task with `task_id` was claimed at `claimed_at`. Run it in
  the claim's transaction, so a claim that rolls back leaves no row.
  """
  @spec record(integer(), DateTime.t()) :: :ok
  def record(task_id, %DateTime{} = claimed_at) when is_integer(task_id) do
    {1, _} = Repo.insert_all(__MODULE__, [%{task_id: task_id, claimed_at: usec(claimed_at)}])
    :ok
  end

  @doc """
  The latest claim of each of `task_ids` that was ever claimed, as
  `%{task_id => claimed_at}`. One query; none for an empty list.
  """
  @spec latest_claims([integer()]) :: %{integer() => DateTime.t()}
  def latest_claims([]), do: %{}

  def latest_claims(task_ids) when is_list(task_ids) do
    from(c in __MODULE__,
      where: c.task_id in ^task_ids,
      group_by: c.task_id,
      select: {c.task_id, max(c.claimed_at)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Whether the task with `task_id` was claimed strictly after `at`.
  """
  @spec claimed_after?(integer(), DateTime.t()) :: boolean()
  def claimed_after?(task_id, %DateTime{} = at) when is_integer(task_id) do
    from(c in __MODULE__, where: c.task_id == ^task_id and c.claimed_at > ^usec(at))
    |> Repo.exists?()
  end

  # `:utc_datetime_usec` refuses a second-precision DateTime, so widen it.
  defp usec(%DateTime{microsecond: {value, _precision}} = at),
    do: %{at | microsecond: {value, 6}}
end
