defmodule Kanban.Notifications.TargetStatusWorker do
  @moduledoc """
  Cron sweeper that tells a delivery target's owner when the target becomes
  at risk or misses its date (`Oban.Plugins.Cron`, hourly at minute 17).

  For each owner of an active target it derives the status of their targets
  through `Kanban.Targets.list_targets_with_status/2` under the owner's own
  scope, the same path the boards strip uses, so goals on boards the owner
  cannot see never feed the status. It then compares each status with the
  target's watermark (`Kanban.Targets.StatusWatermark`):

    * a move into `:at_risk` or `:missed` (including the first observation)
      is recorded and the owner is notified;
    * a move into `:on_track` or `:complete` is recorded silently, so a later
      slip notifies again;
    * an unchanged status does nothing, so re-running a sweep is harmless.

  The watermark is recorded before notifying, with a compare-and-set, so two
  overlapping sweeps notify about a change once. A notification that fails
  after its change was recorded is logged and not retried.

  Status is derived against UTC: no user timezone is stored, while the boards
  strip uses the viewer's browser timezone. When the owner's local day differs
  from the UTC day, a notification can arrive some hours before or after the
  badge they see changes.
  """

  # A sweep that fails is simply re-run by the next cron tick.
  use Oban.Worker, queue: :notifications, max_attempts: 1

  alias Kanban.Accounts.Scope
  alias Kanban.Notifications.Events
  alias Kanban.Targets
  alias Kanban.Targets.StatusWatermark

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    now = sweep_time(args)

    notified =
      Targets.list_active_target_owners()
      |> Enum.map(&sweep_owner(&1, now))
      |> Enum.sum()

    log_sweep(notified)
    :ok
  end

  # One status computation per owner (it is N+1 per target), keeping only the
  # targets this owner owns: the scoped list also holds other owners' targets
  # the owner can see. Returns how many notifications were sent.
  defp sweep_owner(owner, now) do
    owner
    |> Scope.for_user()
    |> Targets.list_targets_with_status(now)
    |> Enum.filter(&(&1.target.owner_id == owner.id))
    |> Enum.count(&(observe(&1, now) == :notified))
  rescue
    exception ->
      Logger.warning(
        "target status sweep failed for owner #{owner.id}: #{inspect(exception.__struct__)}"
      )

      0
  end

  defp observe(%{target: target, status: status}, now) do
    case StatusWatermark.transition(target.last_notified_status, status) do
      :unchanged -> :ok
      action -> record(target, status, now, action)
    end
  end

  defp record(target, status, now, action) do
    case Targets.record_observed_status(target, status, now) do
      {:ok, recorded} when action == :notify ->
        Events.target_status_changed(recorded, status, recorded.status_changed_at)
        :notified

      _recorded_or_stale ->
        :ok
    end
  end

  # "now" (ISO 8601) is a test seam; cron jobs carry empty args.
  defp sweep_time(%{"now" => iso}) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      _error -> utc_now()
    end
  end

  defp sweep_time(_args), do: utc_now()

  defp utc_now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
  end

  defp log_sweep(0), do: :ok
  defp log_sweep(count), do: Logger.info("target status sweep: #{count} notification(s)")
end
