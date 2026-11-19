defmodule Kanban.Reviews.ApprovalChallengePurgeWorker do
  @moduledoc """
  Daily cron job (`Oban.Plugins.Cron`, at 03:53 UTC, on the `:maintenance`
  queue) that deletes expired approval challenges
  (`docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md` §8): every challenge
  whose 2 minutes ran out, used or not, through
  `Kanban.Reviews.Approval.purge_challenges/2`. Running it twice deletes
  nothing the second time.
  """

  # A run that fails is simply re-run by the next day's cron tick.
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  alias Kanban.Reviews.Approval

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _deleted = Approval.purge_challenges(DateTime.utc_now())
    :ok
  end
end
