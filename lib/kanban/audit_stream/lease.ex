defmodule Kanban.AuditStream.Lease do
  @moduledoc """
  The lease one run holds on a destination's cursor while it sends a batch
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §8.1).

  `take/1` is one committed statement: it sets a new `lease_token` and
  `leased_until` 60 seconds ahead only when no live lease exists, so of any
  number of runs at once exactly one gets the cursor. Nothing is held while
  the batch is sent; every later write of the run goes through `guard/2`,
  which locks the cursor row only while it still carries the run's token and
  the lease has not expired. A run whose lease expired, or was taken by
  another run since, can therefore never move the cursor or record an
  outcome.

  Times come from the database clock (`clock_timestamp()`, in UTC, since the
  columns are timestamps without a zone), so runs on several machines compare
  one clock, and a statement inside a longer transaction still reads the
  current time rather than the transaction's start.

  Public so the retention step (§8.6) can take the same lease.
  """

  import Ecto.Query, only: [from: 2]

  alias Kanban.AuditStream.Cursor
  alias Kanban.Repo

  @ttl_seconds 60

  @doc "How long a lease lasts, in seconds."
  @spec ttl() :: pos_integer()
  def ttl, do: @ttl_seconds

  @doc """
  Takes the lease on `destination_id`'s cursor. Returns `{:ok, token}`, or
  `:held` when another run holds a live lease or the destination has no
  cursor.
  """
  @spec take(integer()) :: {:ok, Ecto.UUID.t()} | :held
  def take(destination_id) when is_integer(destination_id) do
    token = Ecto.UUID.generate()

    query =
      from(c in Cursor,
        where:
          c.destination_id == ^destination_id and
            (is_nil(c.leased_until) or
               c.leased_until < fragment("(clock_timestamp() AT TIME ZONE 'UTC')")),
        select: c.lease_token,
        update: [
          set: [
            lease_token: type(^token, Ecto.UUID),
            leased_until:
              fragment("(clock_timestamp() AT TIME ZONE 'UTC') + interval '60 seconds'"),
            updated_at: fragment("(clock_timestamp() AT TIME ZONE 'UTC')")
          ]
        ]
      )

    case Repo.update_all(query, []) do
      {1, [^token]} -> {:ok, token}
      {0, []} -> :held
    end
  end

  @doc """
  The cursor of `destination_id`, locked `FOR UPDATE`, when it still
  carries `token` and its lease has not expired; else nil. Call it inside a
  transaction, before every write the run makes.
  """
  @spec guard(integer(), Ecto.UUID.t()) :: Cursor.t() | nil
  def guard(destination_id, token) when is_integer(destination_id) and is_binary(token) do
    query =
      from(c in Cursor,
        where:
          c.destination_id == ^destination_id and c.lease_token == ^token and
            c.leased_until > fragment("(clock_timestamp() AT TIME ZONE 'UTC')"),
        lock: "FOR UPDATE"
      )

    Repo.one(query)
  end

  @doc """
  Whole seconds, rounded up and at least 0, until the lease on
  `destination_id`'s cursor expires; 0 when no lease is held, and nil when
  the destination has no cursor.
  """
  @spec seconds_left(integer()) :: non_neg_integer() | nil
  def seconds_left(destination_id) when is_integer(destination_id) do
    query =
      from(c in Cursor,
        where: c.destination_id == ^destination_id,
        select:
          fragment(
            "GREATEST(0, CEIL(EXTRACT(EPOCH FROM (COALESCE(?, clock_timestamp() AT TIME ZONE 'UTC') - (clock_timestamp() AT TIME ZONE 'UTC')))))::integer",
            c.leased_until
          )
      )

    Repo.one(query)
  end

  @doc "The cursor fields that release a lease, for a run's last cursor update."
  @spec release_attrs() :: map()
  def release_attrs, do: %{lease_token: nil, leased_until: nil}

  @doc """
  Releases the lease `token` holds on `destination_id`'s cursor. A lease
  another run has taken since is left as it is.
  """
  @spec release(integer(), Ecto.UUID.t()) :: :ok
  def release(destination_id, token) when is_integer(destination_id) and is_binary(token) do
    from(c in Cursor, where: c.destination_id == ^destination_id and c.lease_token == ^token)
    |> Repo.update_all(set: [lease_token: nil, leased_until: nil, updated_at: DateTime.utc_now()])

    :ok
  end
end
