defmodule Kanban.Telemetry.Catalog.AuditStreamEvents do
  @moduledoc """
  The audit log streaming events in `Kanban.Telemetry.Catalog`.

  The streaming worker emits these while it sends an Organization's audit
  events to its destinations. Metadata carries the destination's `kind`
  and a fixed `outcome` or `reason` only, never an Organization id, a URL,
  a host, the destination's name or an email: telemetry can leave the app,
  and a destination's identity must not reach dashboards. `kind`,
  `outcome` and `reason` come from fixed atom sets, so all three are tags.
  The audit actions an org-admin sees (`audit_stream_destination_created`
  and the rest) are `@audit_actions` tuples in
  `Kanban.Telemetry.Catalog.Families`, not entries here.
  `Kanban.Telemetry.Catalog` appends these entries to its own list; nothing
  else should call this module.
  """

  @events [
    %{
      name: [:kanban, :audit_stream, :batch_delivered],
      kind: :event,
      domain: :audit_stream,
      measurements: [:count, :events, :bytes, :duration_ms],
      metadata: [:kind],
      description:
        "A destination accepted a batch of audit events. events is the number of events in the batch, bytes its encoded size and duration_ms how long the request took. kind is the destination's kind.",
      legacy: false,
      metrics: [counter: :count, sum: :events, summary: :duration_ms],
      persist: false,
      tags: [:kind]
    },
    %{
      name: [:kanban, :audit_stream, :batch_failed],
      kind: :event,
      domain: :audit_stream,
      measurements: [:count, :duration_ms],
      metadata: [:kind, :outcome],
      description:
        "A batch of audit events was not accepted. outcome is the fixed failure class of the attempt, never the response body; duration_ms is how long the attempt took. kind is the destination's kind.",
      legacy: false,
      metrics: [counter: :count],
      persist: false,
      tags: [:kind, :outcome]
    },
    %{
      name: [:kanban, :audit_stream, :lag_measured],
      kind: :event,
      domain: :audit_stream,
      measurements: [:lag_seconds, :events_waiting, :events_above_horizon],
      metadata: [:kind],
      description:
        "A destination's delivery lag was measured. lag_seconds is the age of its oldest undelivered event, events_waiting the events not yet sent and events_above_horizon those committed too recently to send safely. kind is the destination's kind.",
      legacy: false,
      metrics: [summary: :lag_seconds],
      persist: true,
      tags: [:kind]
    },
    %{
      name: [:kanban, :audit_stream, :gap_recorded],
      kind: :event,
      domain: :audit_stream,
      measurements: [:count, :events],
      metadata: [:kind, :reason],
      description:
        "Audit events that a destination will never receive were recorded as a gap. events is how many were lost and reason the fixed cause. kind is the destination's kind.",
      legacy: false,
      metrics: [counter: :count],
      persist: false,
      tags: [:kind, :reason]
    }
  ]

  @doc """
  Returns the audit log streaming entries, in declaration order.
  """
  @spec events() :: [Kanban.Telemetry.Catalog.entry()]
  def events, do: @events
end
