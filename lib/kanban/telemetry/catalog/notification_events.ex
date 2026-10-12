defmodule Kanban.Telemetry.Catalog.NotificationEvents do
  @moduledoc """
  The notification, email delivery and weekly digest events in
  `Kanban.Telemetry.Catalog`.

  They are emitted by `Kanban.Notifications.NotificationTelemetry` once the
  change they report has been saved, or once the mailer has answered, so a
  refused or invalid change emits nothing. Email delivery has three outcomes,
  `email_sent`, `email_skipped` and `email_failed`, so delivery health can be
  read without the server logs.

  Metadata carries ids, event types, reason atoms and counts only. Email
  addresses, notification titles and bodies, and raw mailer errors (which
  often echo the recipient address) are never sent, because telemetry
  handlers may forward events to tools outside the app.
  `Kanban.Telemetry.Catalog` appends these entries to its own list; nothing
  else should call this module.
  """

  @events [
    %{
      name: [:kanban, :notification, :created],
      kind: :event,
      domain: :notification,
      measurements: [:count],
      metadata: [:notification_id, :user_id, :event_type, :board_id, :in_app],
      description:
        "A notification was saved for one recipient. user_id is the recipient; in_app is false for an email-only row; board_id is absent for a board-less type.",
      legacy: false
    },
    %{
      name: [:kanban, :notification, :read],
      kind: :event,
      domain: :notification,
      measurements: [:count],
      metadata: [:notification_id, :user_id, :event_type],
      description:
        "A user marked an unread notification read. Marking a read one again emits nothing.",
      legacy: false
    },
    %{
      name: [:kanban, :notification, :all_read],
      kind: :event,
      domain: :notification,
      measurements: [:count],
      metadata: [:user_id],
      description:
        "A user marked all their notifications read. count is the number marked and may be 0.",
      legacy: false
    },
    %{
      name: [:kanban, :notification, :preference_updated],
      kind: :event,
      domain: :notification,
      measurements: [:count],
      metadata: [:user_id, :event_type, :in_app, :mail],
      description:
        "A user's delivery preference for one event type changed. in_app and mail are the saved flags; saving the same flags again emits nothing.",
      legacy: false
    },
    %{
      name: [:kanban, :notification, :unsubscribed],
      kind: :event,
      domain: :notification,
      measurements: [:count],
      metadata: [:user_id, :event_type],
      description:
        "Email for one event type was turned off from an unsubscribe link. user_id comes from the verified link.",
      legacy: false
    },
    %{
      name: [:kanban, :notification, :email_sent],
      kind: :event,
      domain: :notification,
      measurements: [:count],
      metadata: [:notification_id, :user_id, :event_type],
      description: "The mailer accepted a notification email.",
      legacy: false
    },
    %{
      name: [:kanban, :notification, :email_skipped],
      kind: :event,
      domain: :notification,
      measurements: [:count],
      metadata: [:notification_id, :reason],
      description:
        "A notification email job sent nothing. reason is :not_found, :already_emailed, :user_disabled, :user_unconfirmed, :not_a_member or :unsubscribed.",
      legacy: false
    },
    %{
      name: [:kanban, :notification, :email_failed],
      kind: :event,
      domain: :notification,
      measurements: [:count],
      metadata: [:notification_id, :user_id, :event_type, :error],
      description:
        "One notification email delivery attempt failed. error is :permanent_failure, :temporary_failure, :retries_exceeded or :delivery_failed, never the raw mailer reason.",
      legacy: false
    },
    %{
      name: [:kanban, :digest, :sent],
      kind: :event,
      domain: :digest,
      measurements: [:count],
      metadata: [:user_id, :week],
      description:
        "The mailer accepted one user's weekly digest. week is the ISO week, such as \"2026-W45\".",
      legacy: false
    },
    %{
      name: [:kanban, :digest, :fanout_completed],
      kind: :event,
      domain: :digest,
      measurements: [:count],
      metadata: [:week],
      description:
        "The weekly digest fan-out finished enqueuing. count is the number of recipients and may be 0.",
      legacy: false
    }
  ]

  @doc """
  Returns the notification, email delivery and digest entries, in
  declaration order.
  """
  @spec events() :: [Kanban.Telemetry.Catalog.entry()]
  def events, do: @events
end
