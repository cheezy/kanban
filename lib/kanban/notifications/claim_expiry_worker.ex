defmodule Kanban.Notifications.ClaimExpiryWorker do
  @moduledoc """
  Cron sweeper that tells an agent's user when its claim on a task expired
  without the task being completed (`Oban.Plugins.Cron`, every five minutes).

  It never unclaims a task or changes the claim query, and it runs without a
  user scope. `Kanban.Notifications.notify/3` still drops a recipient who is
  no longer a member of the task's board. Each claim is notified once (the
  dedupe key includes `claim_expires_at`), and the lookback window keeps the
  first run from notifying about historical claims.

  Each expired claim also emits `[:kanban, :task, :claim_expired]` once, even
  for a user who left the board or turned the notification off. Its only
  write is the `Kanban.Notifications.ClaimExpiryReport` row that remembers a
  claim was reported; rows older than the lookback window plus a day are
  pruned on every run.

  The lookback defaults to two hours and can be configured with

      config :kanban, Kanban.Notifications.ClaimExpiryWorker, lookback_seconds: 7200
  """

  # A sweep that fails is simply re-run by the next cron tick.
  use Oban.Worker, queue: :notifications, max_attempts: 1

  alias Kanban.Notifications
  alias Kanban.Notifications.ClaimExpiryReport
  alias Kanban.Notifications.Events
  alias Kanban.Tasks.TaskTelemetry

  require Logger

  @default_lookback_seconds 2 * 60 * 60

  # Reports are kept this long past the lookback window, so a late or
  # overlapping sweep still finds the report for a claim it can see.
  @prune_margin_seconds 24 * 60 * 60

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    now = sweep_time(args)
    lookback = lookback_seconds()
    expired = Notifications.list_recently_expired_claims(now, lookback)

    Enum.each(expired, fn task ->
      Events.claim_expired(task)
      report_expiry(task)
    end)

    now
    |> DateTime.add(-(lookback + @prune_margin_seconds), :second)
    |> ClaimExpiryReport.prune()

    log_sweep(length(expired))
    :ok
  end

  defp report_expiry(task) do
    case ClaimExpiryReport.record(task) do
      :new -> TaskTelemetry.claim_expired(task)
      :seen -> :ok
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

  defp lookback_seconds do
    :kanban
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:lookback_seconds, @default_lookback_seconds)
  end

  defp log_sweep(0), do: :ok
  defp log_sweep(count), do: Logger.info("claim expiry sweep: #{count} expired claim(s)")
end
