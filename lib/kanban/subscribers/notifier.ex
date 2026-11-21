defmodule Kanban.Subscribers.Notifier do
  @moduledoc """
  Sends the release list's confirmation email
  (`KanbanWeb.Emails.SubscriberConfirmationEmail`) in the subscriber's
  locale.

  It delivers inline: `Kanban.Subscribers.subscribe/2` already calls it from
  the supervised task that runs a signup off the request, so the signup
  response never waits on the mail server. A failed delivery is logged by
  its kind only, never with the address, the body or the tokens it carries.
  """

  alias Kanban.Mailer
  alias Kanban.Notifications.EmailWorker
  alias Kanban.Subscribers.Subscriber
  alias KanbanWeb.Emails.SubscriberConfirmationEmail

  require Logger

  @doc """
  Builds the confirmation email for `subscriber` with its confirmation and
  unsubscribe tokens, and delivers it. Returns `:ok` even when delivery
  fails, after logging the failure.
  """
  @spec deliver_confirmation(Subscriber.t(), String.t(), String.t()) :: :ok
  def deliver_confirmation(%Subscriber{} = subscriber, confirm_token, unsubscribe_token) do
    email =
      Gettext.with_locale(KanbanWeb.Gettext, subscriber.locale, fn ->
        SubscriberConfirmationEmail.build(subscriber, confirm_token, unsubscribe_token)
      end)

    deliver(email)
  end

  defp deliver(email) do
    case Mailer.deliver(email) do
      {:ok, _metadata} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "release list email delivery failed (kind=#{EmailWorker.failure_kind(reason)})"
        )

        :ok
    end
  end
end
