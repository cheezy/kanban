defmodule Kanban.AuditLog.OrganizationScope do
  @moduledoc """
  Keeps an Organization's audit log to the Organization's own people.

  The org-admin viewer (`KanbanWeb.OrgLive.AuditLog`) and export
  (`KanbanWeb.OrgAuditLogExportController`) show only events linked to the
  org-admin's Organization. Some of those events were caused by someone who is
  not a member of it: a site admin creates an Organization, edits its details
  and appoints or removes its org-admins. Showing that person's email or IP
  address to a customer would expose Stride staff accounts.

  `redact_outside_actors/2` therefore strips, from every event whose actor is
  not a member of the Organization, the actor link, the actor's email (through
  the preloaded user), the IP column, and the `user_id`, `email` and `ip`
  metadata keys, and marks the event `actor_redacted`. Events by members, and
  events with no actor at all, are returned unchanged.
  """
  import Ecto.Query, warn: false

  alias Kanban.AuditLog.AuditEvent
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo

  @identity_keys ["user_id", "email", "ip"]

  @doc """
  Redacts the actor of each event in `events` who is not a member of the
  Organization `organization_id`. Runs one query for the whole batch.
  """
  @spec redact_outside_actors([AuditEvent.t()], pos_integer()) :: [AuditEvent.t()]
  def redact_outside_actors([], _organization_id), do: []

  def redact_outside_actors(events, organization_id) when is_integer(organization_id) do
    members = members_among(events, organization_id)

    Enum.map(events, fn event ->
      if outside_actor?(event, members), do: redact(event), else: event
    end)
  end

  defp members_among(events, organization_id) do
    actor_ids = events |> Enum.map(&actor_id/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    from(m in OrganizationMember,
      where: m.organization_id == ^organization_id and m.user_id in ^actor_ids,
      select: m.user_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # The actor link, or for an actor whose row was nulled or never linked, the
  # id kept in the metadata.
  defp actor_id(%AuditEvent{actor_user_id: id}) when is_integer(id), do: id
  defp actor_id(%AuditEvent{metadata: %{"user_id" => id}}) when is_integer(id), do: id
  defp actor_id(_event), do: nil

  defp outside_actor?(event, members) do
    case actor_id(event) do
      nil -> false
      id -> not MapSet.member?(members, id)
    end
  end

  defp redact(%AuditEvent{} = event) do
    %{
      event
      | actor_user_id: nil,
        actor_user: nil,
        ip: nil,
        metadata: Map.drop(event.metadata || %{}, @identity_keys),
        actor_redacted: true
    }
  end
end
