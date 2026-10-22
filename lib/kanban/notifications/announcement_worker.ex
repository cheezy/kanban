defmodule Kanban.Notifications.AnnouncementWorker do
  @moduledoc """
  Sends one user one service announcement email.

  `Kanban.Notifications.Announcement.fan_out/2` enqueues one job per recipient
  with `%{user_id, key}`. Jobs are unique per `user_id` and `key` in every
  job state for as long as Oban keeps them, so a second fan-out adds no job
  for a user who already has one — cancelled and discarded jobs included, so
  cancelling a bad send and running it again does not re-send to those users.

  `perform/1` re-checks the recipient, so a user disabled after the fan-out
  is skipped. The email renders in the user's stored `locale`, or English
  when they never chose one. It is a service notice, so no notification
  preference or plan gates it.

  Failures are logged — and returned to Oban, which retries — as a bounded
  failure kind plus the user id, never the address or the raw adapter reason.
  """

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 3,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:user_id, :key],
      states: :all
    ]

  alias Kanban.Accounts.User
  alias Kanban.Mailer
  alias Kanban.Notifications.Announcement
  alias Kanban.Notifications.EmailWorker
  alias Kanban.Notifications.NotificationTelemetry
  alias KanbanWeb.Emails.AnnouncementEmail

  require Logger

  @default_locale "en"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "key" => key}})
      when is_integer(user_id) and is_binary(key) do
    with {:ok, key} <- fetch_key(key),
         {:ok, user} <- fetch_recipient(user_id) do
      deliver(user, key)
    else
      {:skip, reason} ->
        Logger.info("announcement for user_id=#{user_id} skipped: #{reason}")
        :ok
    end
  end

  @doc """
  The locale an announcement for `user` renders in: their stored choice when
  the app still supports it, else English.
  """
  @spec locale_for(User.t()) :: String.t()
  def locale_for(%User{locale: locale}) when is_binary(locale) do
    if locale in Gettext.known_locales(KanbanWeb.Gettext), do: locale, else: @default_locale
  end

  def locale_for(%User{}), do: @default_locale

  defp fetch_key(key) do
    if key in Announcement.keys(), do: {:ok, key}, else: {:skip, :unknown_announcement}
  end

  defp fetch_recipient(user_id) do
    case Announcement.get_recipient(user_id) do
      nil -> {:skip, :not_a_recipient}
      user -> {:ok, user}
    end
  end

  defp deliver(user, key) do
    email =
      Gettext.with_locale(KanbanWeb.Gettext, locale_for(user), fn ->
        AnnouncementEmail.build(user, key)
      end)

    case Mailer.deliver(email) do
      {:ok, _metadata} ->
        NotificationTelemetry.announcement_email_sent(user.id, key)

      {:error, reason} ->
        kind = EmailWorker.failure_kind(reason)
        Logger.warning("announcement #{key} delivery failed (user_id=#{user.id}): #{kind}")
        {:error, kind}
    end
  end
end
