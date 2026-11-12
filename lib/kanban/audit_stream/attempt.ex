defmodule Kanban.AuditStream.Attempt do
  @moduledoc """
  One delivery attempt of one batch to one destination
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §9.4): when it started, how long
  it took, what it carried, the HTTP status and its outcome.

  `error` is a short description of what went wrong, cut to 200 characters
  so a long remote error never loses the attempt record.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Kanban.AuditStream.Destination
  alias Kanban.ChangesetText

  @type t :: %__MODULE__{}

  @outcomes [:delivered, :retry, :rejected, :unauthorized, :config_error, :blocked, :skipped]

  @error_max 200

  schema "audit_stream_attempts" do
    belongs_to :destination, Destination
    field :batch_id, Ecto.UUID
    field :started_at, :utc_datetime_usec
    field :duration_ms, :integer
    field :event_count, :integer
    field :bytes, :integer
    field :first_event_id, :integer
    field :last_event_id, :integer
    field :http_status, :integer
    field :outcome, Ecto.Enum, values: @outcomes
    field :error, :string
  end

  @doc "The values `outcome` accepts."
  @spec outcomes() :: [atom()]
  def outcomes, do: @outcomes

  @doc """
  A changeset for an attempt. An `error` longer than 200 characters is cut
  to its first 200.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = attempt, attrs) do
    attempt
    |> cast(attrs, [
      :destination_id,
      :batch_id,
      :started_at,
      :duration_ms,
      :event_count,
      :bytes,
      :first_event_id,
      :last_event_id,
      :http_status,
      :outcome,
      :error
    ])
    |> ChangesetText.validate_storable([:error])
    |> validate_required([:destination_id, :batch_id, :started_at, :outcome])
    |> update_change(:error, &cut_error/1)
    |> foreign_key_constraint(:destination_id)
  end

  # The column is varchar(200), which Postgres counts in codepoints, so the
  # cut counts codepoints too: a grapheme can be several codepoints.
  defp cut_error(error) when is_binary(error),
    do: error |> String.codepoints() |> Enum.take(@error_max) |> Enum.join()

  defp cut_error(error), do: error
end
