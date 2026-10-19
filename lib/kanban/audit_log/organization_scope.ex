defmodule Kanban.AuditLog.OrganizationScope do
  @moduledoc """
  Keeps an Organization's audit log to the Organization's own people.

  The org-admin viewer (`KanbanWeb.OrgLive.AuditLog`) and export
  (`KanbanWeb.OrgAuditLogExportController`) show only events linked to the
  org-admin's Organization. Some of those events were caused by someone who is
  not a member of it: a site admin creates an Organization, edits its details
  and appoints or removes its org-admins. Showing that person's email or IP
  address to a customer would expose Stride staff accounts.

  `redact_outside_actors/2` therefore strips, from every event whose actor was
  not a member of the Organization, the actor link, the actor's email (through
  the preloaded user), the IP column, and the `user_id`, `email` and `ip`
  metadata keys, and marks the event `actor_redacted`. Events by members, and
  events with no actor at all, are returned unchanged.

  Membership is judged as of the event, from its `actor_in_organization`
  column, which `Kanban.AuditLog` fills through `actor_member?/2` when the
  event is written. So an org-admin who later leaves still shows on their past
  actions, and staff who later join the Organization (a site admin appointed
  as org-admin) do not uncover what staff did before. Rows written before the
  column existed have `nil` there and fall back to current membership; they
  all predate launch.
  """
  import Ecto.Query, warn: false

  alias Kanban.AuditLog.AuditEvent
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo

  @identity_keys ["user_id", "email", "ip"]

  @doc """
  Redacts the actor of each event in `events` who was not a member of the
  Organization `organization_id` when the event was written. Runs at most one
  query for the whole batch, for the rows that predate that record.
  """
  @spec redact_outside_actors([AuditEvent.t()], pos_integer()) :: [AuditEvent.t()]
  def redact_outside_actors([], _organization_id), do: []

  def redact_outside_actors(events, organization_id) when is_integer(organization_id) do
    members =
      events |> Enum.filter(&is_nil(&1.actor_in_organization)) |> members_among(organization_id)

    Enum.map(events, fn event ->
      if outside_actor?(event, members), do: redact(event), else: event
    end)
  end

  @doc """
  Whether the user `actor_user_id` is a member of the Organization
  `organization_id` right now, for `Kanban.AuditLog` to store on the event it
  is writing. `nil` when either id is `nil`, since the event then has no actor
  or no Organization to judge. `repo_opts` go to the query, so the writer can
  run it under the same savepoint as its insert.
  """
  @spec actor_member?(pos_integer() | nil, pos_integer() | nil, keyword()) :: boolean() | nil
  def actor_member?(actor_user_id, organization_id, repo_opts \\ [])
  def actor_member?(nil, _organization_id, _repo_opts), do: nil
  def actor_member?(_actor_user_id, nil, _repo_opts), do: nil

  def actor_member?(actor_user_id, organization_id, repo_opts) do
    from(m in OrganizationMember,
      where: m.organization_id == ^organization_id and m.user_id == ^actor_user_id
    )
    |> Repo.exists?(repo_opts)
  end

  defp members_among([], _organization_id), do: MapSet.new()

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

  # The flag stored with the event decides; only a row written before the
  # column existed falls back to current membership.
  defp outside_actor?(%AuditEvent{actor_in_organization: in_organization}, _members)
       when is_boolean(in_organization),
       do: not in_organization

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
