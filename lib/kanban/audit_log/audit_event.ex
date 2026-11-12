defmodule Kanban.AuditLog.AuditEvent do
  @moduledoc """
  One persisted security audit event.

  Rows are written only by `Kanban.AuditLog.event/2` and are append-only: a
  database trigger rejects every `UPDATE` (except the foreign-key cascade that
  nulls `actor_user_id` when a user is deleted), every `TRUNCATE`
  unconditionally, and every `DELETE` outside the retention purge. There is
  therefore no update changeset — `insert_changeset/1` is the only way to build
  one.

  Because a table's owner can disable its triggers, `Kanban.AuditLog.Hardening`
  moves ownership of the table to a separate owner role the application cannot
  assume, when the migration runs as a superuser. The application then removes
  rows only through the purge function `audit_events_purge` (see
  `Kanban.AuditLog.Hardening.Purge`), reached through
  `Kanban.AuditLog.purge_before/1`: in that hardened mode the function belongs
  to the owner role, refuses a cutoff inside the 90-day retention floor, and is
  the application's only path to a delete, because the trigger admits a delete
  only from the table's owner and ignores the transaction-local
  `kanban.audit_purge` flag. Where the table could not be hardened (degraded
  mode) the trigger still admits any delete made while that flag is on, and the
  purge function sets it itself.

  `organization_id` links an event to the Organization it concerns, for the
  org-admin audit log at `/org/audit`. It is nullable, never backfilled, and
  its foreign key has no cascade, because a cascade would have to edit rows the
  trigger protects.

  `actor_in_organization` records whether the actor was a member of that
  Organization when the event was written. It is set only on events with both
  an actor and an Organization, and `nil` on rows recorded before the column
  existed. `Kanban.AuditLog.OrganizationScope` redacts from it.

  `txid` is the id of the transaction that inserted the row, set by the
  column's default (`pg_current_xact_id()`), so audit streaming can read rows
  in (`txid`, `id`) order below its snapshot horizon without skipping a row
  that commits late. That order is not commit order: a transaction that takes
  its id early and commits last sorts first. Rows recorded before the column existed
  read `0`. The field is `writable: :never` and `insert_changeset/1` never
  casts it, so application code never writes it and an insert never names the
  column; a struct returned by an insert therefore carries `txid: nil`, and
  the stored value is read back from the database. The database itself does
  not refuse a `txid` from the application role, whose `INSERT` right covers
  every column — an accepted risk (D10 in
  `docs/plans/AUDIT-LOG-STREAMING-DESIGN.md`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "audit_events" do
    field :action, :string
    field :ip, :string
    field :metadata, :map, default: %{}
    field :actor_in_organization, :boolean

    # Commit order, set only by the column's default (see the moduledoc).
    field :txid, :integer, writable: :never

    # Set only on events read for an Organization's audit log whose actor is
    # not a member of that Organization (see Kanban.AuditLog.OrganizationScope).
    field :actor_redacted, :boolean, virtual: true, default: false

    belongs_to :actor_user, Kanban.Accounts.User
    belongs_to :organization, Kanban.Organizations.Organization

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def insert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :action,
      :actor_user_id,
      :organization_id,
      :ip,
      :metadata,
      :actor_in_organization
    ])
    |> validate_required([:action])
    |> validate_length(:action, max: 255, count: :codepoints)
    |> validate_length(:ip, max: 255, count: :codepoints)
    |> foreign_key_constraint(:actor_user_id)
    |> foreign_key_constraint(:organization_id)
  end
end
