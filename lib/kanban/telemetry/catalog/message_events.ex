defmodule Kanban.Telemetry.Catalog.MessageEvents do
  @moduledoc """
  The admin broadcast message events in `Kanban.Telemetry.Catalog`.

  They are emitted by `Kanban.Messages.MessageTelemetry` once the change they
  report has been saved, so an invalid message or a repeated dismissal emits
  nothing. Metadata carries ids only. A message's title and body are never
  sent, because telemetry handlers may forward events to tools outside the
  app. `Kanban.Telemetry.Catalog` appends these entries to its own list;
  nothing else should call this module.
  """

  @events [
    %{
      name: [:kanban, :message, :created],
      kind: :event,
      domain: :message,
      measurements: [:count],
      metadata: [:message_id, :sender_user_id],
      description: "An administrator published a broadcast message.",
      legacy: false
    },
    %{
      name: [:kanban, :message, :deleted],
      kind: :event,
      domain: :message,
      measurements: [:count],
      metadata: [:message_id, :sender_user_id],
      description:
        "A broadcast message was deleted, with its dismissals. sender_user_id is its author.",
      legacy: false
    },
    %{
      name: [:kanban, :message, :dismissed],
      kind: :event,
      domain: :message,
      measurements: [:count],
      metadata: [:message_id, :user_id],
      description:
        "A user dismissed a broadcast message for the first time. Dismissing it again emits nothing.",
      legacy: false
    }
  ]

  @doc """
  Returns the broadcast message entries, in declaration order.
  """
  @spec events() :: [Kanban.Telemetry.Catalog.entry()]
  def events, do: @events
end
