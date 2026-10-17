defmodule Kanban.Organizations.OrganizationTelemetry do
  @moduledoc """
  Emits the Organization telemetry events through `Kanban.Telemetry` and
  records the matching audit events through `Kanban.AuditLog`.

  Every event is emitted only after the change it reports has been saved, so
  a refused, invalid or rolled-back change emits and records nothing. The
  functions return the result they were given, so they can sit at the end of
  a pipe without changing what the caller sees. An update that changes no
  field emits and records nothing either.

  The membership functions are called once their transaction has returned
  `{:ok, _}`, and pass their work to `Kanban.Telemetry.AfterCommit.defer/2`.
  On their own that runs straight away; when a caller wraps its own
  transaction in `Kanban.Telemetry.AfterCommit.after_commit/1`, as invitation
  acceptance can, it waits for that outer commit too.

  Metadata carries ids and changed field names only. An Organization's name,
  address and contact details never appear in it, because telemetry handlers
  may forward events to tools outside the app.
  """

  alias Ecto.Changeset
  alias Kanban.AuditLog
  alias Kanban.Organizations.Organization
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Telemetry.AfterCommit

  @doc """
  Emits `[:kanban, :organization, :created]` and records the
  `:organization_created` audit event when `result` is a saved
  Organization. Returns `result`.
  """
  @spec created(result, map()) :: result when result: term()
  def created({:ok, %Organization{} = organization} = result, actor) do
    Kanban.Telemetry.emit([:kanban, :organization, :created], %{count: 1}, %{
      organization_id: organization.id,
      actor_user_id: actor.id
    })

    AuditLog.event(:organization_created, user_id: actor.id, organization_id: organization.id)

    result
  end

  def created(result, _actor), do: result

  @doc """
  Emits `[:kanban, :organization, :updated]` and records the
  `:organization_updated` audit event when `result` is a saved Organization
  and the changeset changed at least one field. `fields` lists the changed
  field names, never their values. Returns `result`.
  """
  @spec updated(result, Changeset.t(), map()) :: result when result: term()
  def updated({:ok, %Organization{} = organization} = result, %Changeset{} = changeset, actor) do
    case changed_fields(changeset) do
      [] ->
        result

      fields ->
        Kanban.Telemetry.emit([:kanban, :organization, :updated], %{count: 1}, %{
          organization_id: organization.id,
          actor_user_id: actor.id,
          fields: fields
        })

        AuditLog.event(:organization_updated,
          user_id: actor.id,
          organization_id: organization.id
        )

        result
    end
  end

  def updated(result, _changeset, _actor), do: result

  @doc """
  Emits `[:kanban, :organization, :member_added]` when `change` is `:created`.
  `actor_user_id` is whoever caused the change: the joining user for
  `Kanban.Organizations.add_member/3`. A member who joins this way already had
  an account, so `account_created` is `false`. Returns `:ok`.
  """
  @spec member_added(OrganizationMember.t(), atom(), integer()) :: :ok
  def member_added(%OrganizationMember{} = membership, :created, actor_user_id) do
    AfterCommit.defer(fn -> emit_member_added(membership, actor_user_id, false) end)
  end

  def member_added(%OrganizationMember{}, _change, _actor_user_id), do: :ok

  @doc """
  Records the `:org_admin_appointed` audit event for a new (`:created`) or
  promoted (`:promoted`) org-admin, and emits
  `[:kanban, :organization, :member_added]` when the membership is new. A
  promotion emits no `member_added`, because the user was already a member.
  The site admin is the audit event's `user_id` and the appointee its
  `member_user_id`. `account_created` is `true` in both when the appointee's
  account was created for this appointment, by
  `Kanban.Organizations.appoint_org_admin_by_email/4`. Returns `:ok`.
  """
  @spec org_admin_appointed(OrganizationMember.t(), :created | :promoted, map(), boolean()) ::
          :ok
  def org_admin_appointed(%OrganizationMember{} = membership, change, actor, account_created)
      when change in [:created, :promoted] and is_boolean(account_created) do
    AfterCommit.defer(fn ->
      if change == :created, do: emit_member_added(membership, actor.id, account_created)

      AuditLog.event(:org_admin_appointed,
        user_id: actor.id,
        organization_id: membership.organization_id,
        member_user_id: membership.user_id,
        account_created: account_created
      )
    end)
  end

  @doc """
  Emits `[:kanban, :organization, :member_removed]` and records the
  `:org_admin_removed` audit event for a deleted org-admin membership. The site
  admin is the audit event's `user_id` and the removed org-admin its
  `member_user_id`. Returns `:ok`.
  """
  @spec org_admin_removed(OrganizationMember.t(), map()) :: :ok
  def org_admin_removed(%OrganizationMember{} = membership, actor) do
    AfterCommit.defer(fn ->
      Kanban.Telemetry.emit([:kanban, :organization, :member_removed], %{count: 1}, %{
        organization_id: membership.organization_id,
        user_id: membership.user_id,
        role: membership.role,
        actor_user_id: actor.id
      })

      AuditLog.event(:org_admin_removed,
        user_id: actor.id,
        organization_id: membership.organization_id,
        member_user_id: membership.user_id
      )
    end)
  end

  defp emit_member_added(%OrganizationMember{} = membership, actor_user_id, account_created) do
    Kanban.Telemetry.emit([:kanban, :organization, :member_added], %{count: 1}, %{
      organization_id: membership.organization_id,
      user_id: membership.user_id,
      role: membership.role,
      actor_user_id: actor_user_id,
      account_created: account_created
    })
  end

  defp changed_fields(%Changeset{changes: changes}) do
    changes
    |> Map.keys()
    |> Enum.sort()
  end
end
