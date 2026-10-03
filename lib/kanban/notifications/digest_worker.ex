defmodule Kanban.Notifications.DigestWorker do
  @moduledoc """
  Sends one user's weekly digest email for one ISO week.

  `Kanban.Notifications.DigestFanoutWorker` enqueues one job per recipient
  with `%{user_id, week, now}`. Jobs are unique per `user_id` and `week` for
  as long as Oban keeps them, and a `:weekly_digest` notification row with
  the dedupe key `"weekly_digest:<week>"` is the durable guard: it is
  inserted before sending, so a second job for the same week sends nothing.
  The row has `in_app: false`, so it never shows in the inbox or the badge.

  `perform/1` re-checks the recipient (confirmed, enabled, opted in, on at
  least one board) and builds the digest with the fan-out's `now`, so a
  retried job reports the same week. Quiet weeks send nothing and leave no
  row. This worker never calls `Kanban.Notifications.notify/3`, which would
  enqueue a second email through `Kanban.Notifications.EmailWorker`.

  Delivery is at-most-once: the row is claimed before sending and deleted
  again when the mailer returns an error, so Oban's retry can send. A crash
  between the claim and the send drops that user's digest for the week,
  which is preferable to emailing it twice. The stable `Message-ID` covers
  a mailer that accepted the email but reported an error.

  Failures are logged — and returned to Oban — as a bounded failure kind
  plus the user id, never the address, names or the raw adapter reason.
  """

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :args], keys: [:user_id, :week]]

  import Ecto.Query, warn: false

  alias Kanban.Mailer
  alias Kanban.Notifications.Digest
  alias Kanban.Notifications.DigestRecipients
  alias Kanban.Notifications.EmailWorker
  alias Kanban.Notifications.Notification
  alias Kanban.Repo
  alias KanbanWeb.Emails.DigestEmail

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "week" => week} = args})
      when is_integer(user_id) and is_binary(week) do
    user_id
    |> send_digest(week, Digest.parse_now(args))
    |> log_outcome(user_id)
  end

  defp send_digest(user_id, week, now) do
    with {:ok, user} <- fetch_recipient(user_id),
         {:ok, digest} <- build_digest(user, now),
         {:ok, record} <- claim_week(user, week) do
      deliver(record, user, digest, week)
    end
  end

  defp log_outcome({:skip, reason}, user_id) do
    Logger.info("weekly digest for user_id=#{user_id} skipped: #{reason}")
    :ok
  end

  defp log_outcome({:error, :record_failed} = error, user_id) do
    Logger.warning("weekly digest record failed (user_id=#{user_id})")
    error
  end

  # :ok, or a delivery error deliver/4 has already logged.
  defp log_outcome(result, _user_id), do: result

  defp fetch_recipient(user_id) do
    case DigestRecipients.get_digest_recipient(user_id) do
      nil -> {:skip, :not_a_recipient}
      user -> {:ok, user}
    end
  end

  defp build_digest(user, now) do
    case Digest.build(user, now: now) do
      :empty -> {:skip, :empty}
      digest -> {:ok, digest}
    end
  end

  # The unique index on [:user_id, :dedupe_key] makes the claim atomic: a
  # conflicting insert returns a struct without an id.
  defp claim_week(user, week) do
    %Notification{user_id: user.id, event_type: :weekly_digest, in_app: false}
    |> Notification.changeset(%{
      title: "Weekly digest #{week}",
      url_path: "/users/notifications",
      dedupe_key: "weekly_digest:#{week}",
      metadata: %{"week" => week}
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :dedupe_key])
    |> case do
      {:ok, %Notification{id: nil}} -> {:skip, :already_sent}
      {:ok, record} -> {:ok, record}
      # Unexpected (e.g. the user was deleted mid-job): let Oban retry, where
      # fetch_recipient/1 then skips a deleted user.
      {:error, _changeset} -> {:error, :record_failed}
    end
  end

  defp deliver(record, user, digest, week) do
    case user |> DigestEmail.build(digest, week) |> Mailer.deliver() do
      {:ok, _metadata} ->
        stamp_emailed(record)
        :ok

      {:error, reason} ->
        Repo.delete(record)
        kind = EmailWorker.failure_kind(reason)
        Logger.warning("weekly digest delivery failed (user_id=#{user.id}): #{kind}")
        {:error, kind}
    end
  end

  defp stamp_emailed(%Notification{id: id}) do
    Notification
    |> where([n], n.id == ^id and is_nil(n.emailed_at))
    |> Repo.update_all(set: [emailed_at: DateTime.utc_now()])
  end
end
