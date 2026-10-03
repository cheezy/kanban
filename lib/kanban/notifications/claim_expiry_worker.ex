defmodule Kanban.Notifications.ClaimExpiryWorker do
  @moduledoc """
  Cron sweeper that tells an agent's user when its claim on a task expired
  without the task being completed (`Oban.Plugins.Cron`, every five minutes).

  It only reads: it never unclaims a task or changes the claim query, and it
  runs without a user scope. `Kanban.Notifications.notify/3` still drops a
  recipient who is no longer a member of the task's board. Each claim is
  notified once (the dedupe key includes `claim_expires_at`), and the
  lookback window keeps the first run from notifying about historical claims.

  The lookback defaults to two hours and can be configured with

      config :kanban, Kanban.Notifications.ClaimExpiryWorker, lookback_seconds: 7200
  """

  # A sweep that fails is simply re-run by the next cron tick.
  use Oban.Worker, queue: :notifications, max_attempts: 1

  alias Kanban.Notifications
  alias Kanban.Notifications.Events

  require Logger

  @default_lookback_seconds 2 * 60 * 60

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    expired =
      args
      |> sweep_time()
      |> Notifications.list_recently_expired_claims(lookback_seconds())

    Enum.each(expired, &Events.claim_expired/1)
    log_sweep(length(expired))
    :ok
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
