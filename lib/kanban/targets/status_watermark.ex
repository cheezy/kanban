defmodule Kanban.Targets.StatusWatermark do
  @moduledoc """
  The target-status sweeper's watermark: the last delivery status
  `Kanban.Notifications.TargetStatusWorker` observed for each target, so a
  change is noticed (and its owner notified) once.

  The watermark is not a status source. Every read path keeps deriving a
  target's status with `Kanban.Targets.list_targets_with_status/2`; only the
  sweeper reads `last_notified_status`.

  Exposed through the `Kanban.Targets` facade via `defdelegate` for
  `list_active_target_owners/0` and `record_observed_status/3`.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Repo
  alias Kanban.Targets.DeliveryTarget
  alias Kanban.Targets.Status

  @alert_statuses [:at_risk, :missed]

  @doc """
  Decides what the sweeper does when a target's derived status is `current`
  and its watermark is `previous`:

    * `:unchanged` — the status is the one already recorded;
    * `:notify` — the status moved into `:at_risk` or `:missed`, including
      the first observation and a move between those two;
    * `:record` — any other move (into `:on_track` or `:complete`), recorded
      silently so a later slip notifies again. A first observation of a
      healthy target is recorded silently too, so existing targets do not all
      notify on the first run.
  """
  @spec transition(String.t() | nil, Status.status()) :: :unchanged | :notify | :record
  def transition(previous, current) when is_atom(current) do
    cond do
      Atom.to_string(current) == previous -> :unchanged
      current in @alert_statuses -> :notify
      true -> :record
    end
  end

  @doc """
  Returns the owners of every active (unarchived) delivery target, ordered
  by id. Reads across all users without a scope, so it is for the sweeper
  only.
  """
  @spec list_active_target_owners() :: [User.t()]
  def list_active_target_owners do
    owner_ids =
      from dt in DeliveryTarget,
        where: is_nil(dt.archived_at) and not is_nil(dt.owner_id),
        select: dt.owner_id

    User
    |> where([u], u.id in subquery(owner_ids))
    |> order_by([u], asc: u.id)
    |> Repo.all()
  end

  @doc """
  Records `status` as `target`'s watermark, changed at `observed_at`.

  The write only lands if the stored watermark still equals the one on
  `target`, so when two sweeps overlap only one of them records (and
  notifies about) a given change; the other gets `{:error, :stale}`.
  """
  @spec record_observed_status(DeliveryTarget.t(), Status.status(), DateTime.t()) ::
          {:ok, DeliveryTarget.t()} | {:error, :stale | Ecto.Changeset.t()}
  def record_observed_status(%DeliveryTarget{} = target, status, %DateTime{} = observed_at)
      when is_atom(status) do
    target
    |> DeliveryTarget.status_changeset(%{
      last_notified_status: Atom.to_string(status),
      status_changed_at: DateTime.truncate(observed_at, :second)
    })
    |> Ecto.Changeset.apply_action(:update)
    |> case do
      {:ok, updated} -> compare_and_set(target, updated)
      {:error, _changeset} = error -> error
    end
  end

  # update_all also leaves updated_at alone: this is not an edit of the target.
  defp compare_and_set(%DeliveryTarget{id: id, last_notified_status: previous}, updated) do
    DeliveryTarget
    |> where([dt], dt.id == ^id)
    |> where_watermark(previous)
    |> select([dt], dt)
    |> Repo.update_all(
      set: [
        last_notified_status: updated.last_notified_status,
        status_changed_at: updated.status_changed_at
      ]
    )
    |> case do
      {1, [recorded]} -> {:ok, recorded}
      {0, _} -> {:error, :stale}
    end
  end

  defp where_watermark(query, nil), do: where(query, [dt], is_nil(dt.last_notified_status))

  defp where_watermark(query, previous),
    do: where(query, [dt], dt.last_notified_status == ^previous)
end
