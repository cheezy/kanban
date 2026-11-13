defmodule Kanban.AuditStream.DestinationEvents do
  @moduledoc """
  The audit events `Kanban.AuditStream.Destinations`,
  `Kanban.AuditStream.BatchActions`, `Kanban.AuditStream.TestEvent` and
  `Kanban.AuditStream.DispatchWorker` record, with the keys
  `docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §13.2 lists. Each is a literal
  `AuditLog.event/2` call so the telemetry call-site tests see it.

  No secret, URL or credential is ever passed: a destination is named by its
  id, kind, name and host only (§12.2). Called inside the transaction that
  makes the change, so an event never commits without its change.
  `AuditLog.event/2` logs rather than raises when its own insert fails.
  """

  alias Kanban.AuditLog

  @doc "Records `audit_stream_destination_created`."
  def created(destination, actor, start_from) do
    AuditLog.event(:audit_stream_destination_created,
      user_id: actor.id,
      organization_id: destination.organization_id,
      destination_id: destination.id,
      kind: destination.kind,
      start_from: start_from,
      include_personal_data: destination.include_personal_data,
      destination_name: destination.name,
      url_host: destination.url_host
    )
  end

  @doc "Records `audit_stream_destination_updated`; `changed` holds field names only."
  def updated(destination, actor, changed) do
    AuditLog.event(:audit_stream_destination_updated,
      user_id: actor.id,
      organization_id: destination.organization_id,
      destination_id: destination.id,
      kind: destination.kind,
      changed: changed,
      destination_name: destination.name,
      url_host: destination.url_host
    )
  end

  @doc "Records `audit_stream_destination_paused` (`false`) or `_resumed` (`true`)."
  def enabled(destination, actor, false) do
    AuditLog.event(:audit_stream_destination_paused,
      user_id: actor.id,
      organization_id: destination.organization_id,
      destination_id: destination.id,
      kind: destination.kind,
      destination_name: destination.name
    )
  end

  def enabled(destination, actor, true) do
    AuditLog.event(:audit_stream_destination_resumed,
      user_id: actor.id,
      organization_id: destination.organization_id,
      destination_id: destination.id,
      kind: destination.kind,
      destination_name: destination.name
    )
  end

  @doc "Records `audit_stream_destination_deleted`."
  def deleted(destination, actor) do
    AuditLog.event(:audit_stream_destination_deleted,
      user_id: actor.id,
      organization_id: destination.organization_id,
      destination_id: destination.id,
      kind: destination.kind,
      destination_name: destination.name
    )
  end

  @doc """
  Records `audit_stream_failing` with its fixed `reason`. Recorded by the
  system, so no `user_id` is set.
  """
  def failing(destination, reason) do
    AuditLog.event(:audit_stream_failing,
      organization_id: destination.organization_id,
      destination_id: destination.id,
      kind: destination.kind,
      reason: reason
    )
  end

  @doc """
  Records `audit_stream_recovered`. Recorded by the system, so no `user_id`
  is set.
  """
  def recovered(destination) do
    AuditLog.event(:audit_stream_recovered,
      organization_id: destination.organization_id,
      destination_id: destination.id,
      kind: destination.kind
    )
  end

  @doc """
  Records `audit_stream_test_sent` with the test's coarse `outcome` only,
  never a status, a body or a transport detail (§12.5).
  """
  def test_sent(destination, actor, outcome) do
    AuditLog.event(:audit_stream_test_sent,
      user_id: actor.id,
      organization_id: destination.organization_id,
      destination_id: destination.id,
      outcome: outcome
    )
  end

  @doc """
  Records `audit_stream_batch_skipped`: how many events were skipped, the
  first and last event ids of the pending batch, and the HTTP status of the
  destination's last answer to it.
  """
  def batch_skipped(destination, actor, skipped) do
    AuditLog.event(:audit_stream_batch_skipped,
      user_id: actor.id,
      organization_id: destination.organization_id,
      destination_id: destination.id,
      kind: destination.kind,
      events: skipped.events,
      http_status: skipped.http_status,
      first_event_id: skipped.first_event_id,
      last_event_id: skipped.last_event_id
    )
  end

  @doc "Records `audit_stream_signing_secret_rotated`."
  def rotated(destination, actor) do
    AuditLog.event(:audit_stream_signing_secret_rotated,
      user_id: actor.id,
      organization_id: destination.organization_id,
      destination_id: destination.id
    )
  end
end
