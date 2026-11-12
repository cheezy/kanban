defmodule Kanban.AuditStream.Gap do
  @moduledoc """
  A run of audit events one destination never received
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §9.6): because they were
  deleted by retention before they were sent, or were too old for the
  destination to accept.

  A gap counts its `events`, spans `first_occurred_at` to
  `last_occurred_at`, and records when it opened, when it last grew, when it
  was emailed and audited, and who dismissed it and when.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Kanban.Accounts.User
  alias Kanban.AuditStream.Destination

  @type t :: %__MODULE__{}

  @reasons [:retention, :too_old]

  schema "audit_stream_gaps" do
    belongs_to :destination, Destination
    field :reason, Ecto.Enum, values: @reasons
    field :events, :integer, default: 0
    field :first_occurred_at, :utc_datetime_usec
    field :last_occurred_at, :utc_datetime_usec
    field :opened_at, :utc_datetime_usec
    field :last_extended_at, :utc_datetime_usec
    field :emailed_at, :utc_datetime_usec
    field :audited_at, :utc_datetime_usec
    field :dismissed_at, :utc_datetime_usec
    belongs_to :dismissed_by, User
  end

  @doc "The values `reason` accepts."
  @spec reasons() :: [atom()]
  def reasons, do: @reasons

  @doc "A changeset for a gap. Dismissal is `dismiss_changeset/3`."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = gap, attrs) do
    gap
    |> cast(attrs, [
      :destination_id,
      :reason,
      :events,
      :first_occurred_at,
      :last_occurred_at,
      :opened_at,
      :last_extended_at,
      :emailed_at,
      :audited_at
    ])
    |> validate_required([
      :destination_id,
      :reason,
      :first_occurred_at,
      :last_occurred_at,
      :opened_at,
      :last_extended_at
    ])
    |> validate_number(:events, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:destination_id)
  end

  @doc "Marks `gap` dismissed by the user with id `user_id` at `at`."
  @spec dismiss_changeset(t(), pos_integer(), DateTime.t()) :: Ecto.Changeset.t()
  def dismiss_changeset(%__MODULE__{} = gap, user_id, %DateTime{} = at)
      when is_integer(user_id) do
    change(gap, dismissed_at: at, dismissed_by_id: user_id)
  end
end
