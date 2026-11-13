defmodule Kanban.AuditStream.Cursor do
  @moduledoc """
  How far one destination has streamed, and the batch it is sending
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §9.3).

  One row per destination, keyed by `destination_id`. It is a table of its
  own so the worker's frequent writes never conflict with an org-admin
  editing the destination. `last_txid` and `last_event_id` are the (`txid`,
  `id`) position of the last event delivered; they have no default, because
  a cursor at zero would silently stream the whole log.

  The `pending_` fields describe the batch being sent: its id, its range, how
  many attempts it has had and the destination's `filter_version` it was cut
  under, so a filter change discards it (D16). `leased_until` and
  `lease_token` hold the lease of the run sending it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Kanban.AuditStream.Destination

  @type t :: %__MODULE__{}

  @primary_key {:destination_id, :id, autogenerate: false}

  schema "audit_stream_cursors" do
    belongs_to :destination, Destination, define_field: false
    field :last_txid, :integer
    field :last_event_id, :integer
    field :last_inserted_at, :utc_datetime_usec
    field :not_before, :utc_datetime_usec
    field :pending_batch_id, Ecto.UUID
    field :pending_first_txid, :integer
    field :pending_first_id, :integer
    field :pending_last_txid, :integer
    field :pending_last_id, :integer
    field :pending_attempts, :integer, default: 0
    field :pending_filter_version, :integer
    field :next_attempt_at, :utc_datetime_usec
    field :leased_until, :utc_datetime_usec
    field :lease_token, Ecto.UUID
    field :restored_max_event_id, :integer
    field :restored_min_txid, :integer

    timestamps(type: :utc_datetime_usec, inserted_at: false)
  end

  @doc """
  A changeset for every cursor field. `destination_id` is set on the struct
  by the caller, never cast.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = cursor, attrs) do
    cursor
    |> cast(attrs, [
      :last_txid,
      :last_event_id,
      :last_inserted_at,
      :not_before,
      :pending_batch_id,
      :pending_first_txid,
      :pending_first_id,
      :pending_last_txid,
      :pending_last_id,
      :pending_attempts,
      :pending_filter_version,
      :next_attempt_at,
      :leased_until,
      :lease_token,
      :restored_max_event_id,
      :restored_min_txid
    ])
    |> validate_required([:last_txid, :last_event_id])
    |> validate_number(:last_txid, greater_than_or_equal_to: 0)
    |> validate_number(:last_event_id, greater_than_or_equal_to: 0)
    |> validate_number(:pending_attempts, greater_than_or_equal_to: 0)
    |> validate_number(:pending_filter_version, greater_than_or_equal_to: 1)
    |> validate_restored_bound()
    |> check_constraint(:restored_max_event_id,
      name: :audit_stream_cursors_restored_bound_complete
    )
    |> foreign_key_constraint(:destination_id)
    |> unique_constraint(:destination_id, name: :audit_stream_cursors_pkey)
  end

  # Both bounds or neither: half a bound would hide nothing or everything.
  defp validate_restored_bound(changeset) do
    max_id = get_field(changeset, :restored_max_event_id)
    min_txid = get_field(changeset, :restored_min_txid)

    if is_nil(max_id) == is_nil(min_txid),
      do: changeset,
      else: add_error(changeset, :restored_max_event_id, "must be set with restored_min_txid")
  end
end
