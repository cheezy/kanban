defmodule Kanban.Organizations.OrganizationTelemetry do
  @moduledoc """
  Emits the Organization telemetry events through `Kanban.Telemetry` and
  records the matching audit events through `Kanban.AuditLog`.

  Every event is emitted only after the change it reports has been saved, so
  a refused, invalid or rolled-back change emits and records nothing. The
  functions return the result they were given, so they can sit at the end of
  a pipe without changing what the caller sees. An update that changes no
  field emits and records nothing either.

  Metadata carries ids and changed field names only. An Organization's name,
  address and contact details never appear in it, because telemetry handlers
  may forward events to tools outside the app.
  """

  alias Ecto.Changeset
  alias Kanban.AuditLog
  alias Kanban.Organizations.Organization

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

  defp changed_fields(%Changeset{changes: changes}) do
    changes
    |> Map.keys()
    |> Enum.sort()
  end
end
