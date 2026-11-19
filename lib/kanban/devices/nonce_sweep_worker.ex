defmodule Kanban.Devices.NonceSweepWorker do
  @moduledoc """
  Hourly cron job (`Oban.Plugins.Cron`, at minute 37, on the `:maintenance`
  queue) that deletes expired device nonces
  (`docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md` §8): every row in
  `device_nonces` whose `expires_at` has passed, through
  `Kanban.Devices.Nonces.sweep_expired/2`. Running it twice deletes nothing
  the second time.
  """

  # A run that fails is simply re-run by the next hour's cron tick.
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  alias Kanban.Devices.Nonces

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _deleted = Nonces.sweep_expired(DateTime.utc_now())
    :ok
  end
end
