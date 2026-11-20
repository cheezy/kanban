defmodule Kanban.Notifications.ExpiredClaims do
  @moduledoc """
  The read `Kanban.Notifications.ClaimExpiryWorker` sweeps: tasks whose
  agent claim expired recently and that are still being worked.

  Read-only; it never unclaims anything.
  """

  import Ecto.Query, warn: false

  alias Kanban.Columns
  alias Kanban.Repo
  alias Kanban.Tasks.Task

  @doc """
  Lists tasks whose agent claim expired in the half-open window
  `[now - lookback_seconds, now)` and that are still being worked: in
  progress, in the Doing column (its name matched as `Kanban.Columns.named?/2`
  matches it, case and surrounding whitespace ignored), assigned, unarchived,
  agent work or defect.

  The expiry test mirrors the claim query (`claim_expires_at < now`). Tasks in
  Review are excluded on purpose: completing a task keeps its old
  `claim_expires_at`, so without the Doing filter every task awaiting review
  would look expired. Read-only; never unclaims anything.
  """
  @spec list_recently_expired_claims(DateTime.t(), pos_integer()) :: [Task.t()]
  def list_recently_expired_claims(%DateTime{} = now, lookback_seconds)
      when is_integer(lookback_seconds) and lookback_seconds > 0 do
    since = DateTime.add(now, -lookback_seconds, :second)

    from(t in Task,
      join: c in assoc(t, :column),
      as: :column,
      where: ^Columns.name_matches(:column, "Doing"),
      where: t.status == :in_progress and is_nil(t.archived_at),
      where: not is_nil(t.assigned_to_id),
      where: t.claim_expires_at < ^now and t.claim_expires_at >= ^since,
      where: t.type in [:work, :defect] and t.human_task == false,
      order_by: [asc: t.claim_expires_at, asc: t.id]
    )
    |> Repo.all()
  end
end
