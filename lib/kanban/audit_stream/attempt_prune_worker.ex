defmodule Kanban.AuditStream.AttemptPruneWorker do
  @moduledoc """
  Hourly cron job (`Oban.Plugins.Cron`, at minute 29, on the `:maintenance`
  queue) that prunes audit stream attempts
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §8.7): attempts are kept for 7
  days, and at most the newest 200 per destination
  (`Kanban.AuditStream.prune_attempts/1`). Gaps are not attempts, so pruning
  never removes one. Running it twice removes nothing the second time.
  """

  # A run that fails is simply re-run by the next hour's cron tick.
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  alias Kanban.AuditStream

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _deleted = AuditStream.prune_attempts(DateTime.utc_now())
    :ok
  end
end
