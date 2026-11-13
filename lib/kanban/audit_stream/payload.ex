defmodule Kanban.AuditStream.Payload do
  @moduledoc """
  Builds the `stride.audit.v1` event object every destination carries
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §6).

  The values come from the stored row through
  `Kanban.AuditLog.Export.row_map/1`; only the names and shape differ, for a
  tool outside Stride. The event is one `Kanban.AuditStream.Reader` returned,
  so outside actors are already redacted (`actor_redacted: true`) and, when a
  destination leaves personal data out, email and IP are already removed.
  This module only maps:

    * `id` is a string, so a 64-bit id survives JavaScript tools;
    * `action_label` is the English label from `KanbanWeb.AuditLogActions`,
      whatever locale is active when the payload is built;
    * `organization` is the Organization's id and name, passed in because
      the Reader does not preload it. For a streamed batch they are the ones
      stored when the batch was cut, so every retry of a `batch_id` carries
      the same name (`Kanban.AuditStream.PendingBatch`, D428);
    * `actor.in_organization` is always a boolean: false for a redacted actor
      or an event with no actor, the stored flag when there is one, and for a
      row written before that flag existed, which the Reader did not redact,
      true (the current-membership fallback `Kanban.AuditLog.OrganizationScope`
      applies);
    * a redacted actor has a null `user_id`, `email` and `ip`;
    * `instance` is the endpoint host, unless the `:instance` option is given.
  """

  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditLog.Export
  alias KanbanWeb.AuditLogActions

  @schema "stride.audit.v1"

  @typedoc "A built event: a JSON-ready map with string keys."
  @type t :: %{String.t() => term()}

  @typedoc "The Organization an event belongs to."
  @type organization :: %{required(:id) => pos_integer(), required(:name) => String.t()}

  @doc "The schema name every event carries."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc """
  The `organization` object of a payload or batch: the id and name.
  """
  @spec organization(organization()) :: %{String.t() => term()}
  def organization(%{id: id, name: name}), do: %{"id" => id, "name" => name}

  @doc """
  Builds the §6 object for `event` in `organization`.

  Options: `:instance`, the host named in the event (defaults to
  `KanbanWeb.Endpoint.host/0`).
  """
  @spec build(AuditEvent.t(), organization(), keyword()) :: t()
  def build(%AuditEvent{} = event, organization, opts \\ []) do
    row = Export.row_map(event)

    row
    |> event_fields()
    |> Map.merge(%{
      "organization" => organization(organization),
      "actor" => actor(event, row),
      "ip" => identity(event, row["ip"]),
      "instance" => Keyword.get_lazy(opts, :instance, &KanbanWeb.Endpoint.host/0)
    })
  end

  defp event_fields(row) do
    %{
      "id" => Integer.to_string(row["id"]),
      "schema" => @schema,
      "occurred_at" => row["inserted_at"],
      "action" => row["action"],
      "action_label" => english_label(row["action"]),
      "metadata" => row["metadata"]
    }
  end

  defp english_label(action) do
    Gettext.with_locale(KanbanWeb.Gettext, "en", fn -> AuditLogActions.action_label(action) end)
  end

  defp actor(event, row) do
    %{
      "user_id" => identity(event, row["actor_user_id"]),
      "email" => identity(event, row["actor_email"]),
      "in_organization" => in_organization?(event, row["actor_user_id"])
    }
  end

  # A redacted actor's identity is null even if a value survived upstream.
  defp identity(%AuditEvent{actor_redacted: true}, _value), do: nil
  defp identity(_event, value), do: value

  defp in_organization?(%AuditEvent{actor_redacted: true}, _actor_user_id), do: false

  defp in_organization?(%AuditEvent{actor_in_organization: flag}, _actor_user_id)
       when is_boolean(flag),
       do: flag

  defp in_organization?(_event, actor_user_id), do: not is_nil(actor_user_id)
end
