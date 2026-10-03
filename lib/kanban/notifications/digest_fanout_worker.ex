defmodule Kanban.Notifications.DigestFanoutWorker do
  @moduledoc """
  Weekly cron job (`Oban.Plugins.Cron`, Mondays 13:00 UTC) that enqueues one
  `Kanban.Notifications.DigestWorker` job per digest recipient.

  It only reads users and inserts jobs; each per-user job builds and sends
  its own email, so one slow or failing mailbox never holds up the rest.
  Every job carries the ISO week and the fan-out's `now`, and jobs are
  unique per user and week, so re-running the fan-out (a retry, or by hand)
  never enqueues a second digest for the same week.
  """

  # Unlike the five-minute claim-expiry sweep, a failed weekly fan-out has no
  # next tick to fall back on, so it retries; uniqueness makes that safe.
  use Oban.Worker, queue: :notifications, max_attempts: 3

  alias Kanban.Notifications
  alias Kanban.Notifications.Digest
  alias Kanban.Notifications.DigestWorker

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    now = Digest.parse_now(args)
    week = Digest.iso_week(now)
    recipients = Notifications.list_digest_recipients()

    Enum.each(recipients, &enqueue(&1, week, now))
    Logger.info("weekly digest fan-out for #{week}: #{length(recipients)} recipient(s)")
    :ok
  end

  # Oban.insert_all ignores `unique` on the Basic engine, so insert one by one.
  defp enqueue(user_id, week, now) do
    %{user_id: user_id, week: week, now: DateTime.to_iso8601(now)}
    |> DigestWorker.new()
    |> Oban.insert!()
  end
end
