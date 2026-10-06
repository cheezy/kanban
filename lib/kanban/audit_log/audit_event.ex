defmodule Kanban.AuditLog.AuditEvent do
  @moduledoc """
  One persisted security audit event.

  Rows are written only by `Kanban.AuditLog.event/2` and are append-only: a
  database trigger rejects every `UPDATE` (except the foreign-key cascade that
  nulls `actor_user_id` when a user is deleted), every `TRUNCATE`
  unconditionally, and every `DELETE` unless the transaction-local
  `kanban.audit_purge` setting is on — the only gate a retention purge can use.
  There is therefore no update changeset — `insert_changeset/1` is the only way
  to build one.

  Because a table's owner can disable its triggers, `Kanban.AuditLog.Hardening`
  moves ownership of the table to a role the application cannot assume, when
  the migration runs as a superuser.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "audit_events" do
    field :action, :string
    field :ip, :string
    field :metadata, :map, default: %{}

    belongs_to :actor_user, Kanban.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def insert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:action, :actor_user_id, :ip, :metadata])
    |> validate_required([:action])
    |> validate_length(:action, max: 255, count: :codepoints)
    |> validate_length(:ip, max: 255, count: :codepoints)
    |> foreign_key_constraint(:actor_user_id)
  end
end
