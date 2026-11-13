defmodule Kanban.AuditStream.Reader do
  @moduledoc """
  Reads one Organization's audit events for an audit stream destination, in
  (`txid`, `id`) order below the snapshot horizon
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §7.2).

  `audit_events.txid` is the id of the transaction that inserted the row. The
  reader only returns rows whose `txid` is below the horizon, the oldest
  transaction still running (`pg_snapshot_xmin(pg_current_snapshot())`).
  Every transaction older than that has finished, so the rows below it are
  final and a (`txid`, `id`) cursor that only moves over them never skips a row
  that commits late.

  The horizon is the `:horizon` option. A test in the Ecto SQL sandbox runs
  inside one open transaction, and its rows carry that transaction's id, which
  is never below its own horizon; such tests pass a `:horizon` above their own
  transaction id.

  `organization_id` must come from the destination row, never from user input:
  it is the only thing that keeps one Organization's events out of another's
  destination. It must be an integer, so an unscoped read is impossible. Rows
  with no Organization (site events) are never read.

  Every read that returns events (`next_batch/3` and `read_range/4`) preloads
  the actor and redacts actors from outside the Organization with
  `Kanban.AuditLog.OrganizationScope.redact_outside_actors/2`, exactly as the
  Organization audit page does. With `include_personal_data: false` it then
  sets the `ip` column to `nil`, removes the preloaded actor's email (keeping
  `actor_user_id`) and removes every `email` and `ip` key from the metadata,
  at any depth, including inside lists (§6).

  ## Options

  Every function takes the destination's filters:

    * `:not_before` - a `DateTime`; only events inserted at or after it are
      read. It filters by time only and never moves the cursor (§8.5).
    * `:excluded_actions` - action names (strings or atoms) never read.
    * `:include_personal_data` - `true` (default) or `false`, as above. It
      changes no count in `waiting_counts/3`.

  `next_batch/3` also takes `:horizon`, `:batch_size` (default 500),
  `:max_bytes` (default 900_000) and `:size_fun`; `waiting_counts/3`,
  `next_waiting_at/3` and `too_old/4` take `:horizon`; `loss_counts/4`
  takes `:through`. An unknown or invalid option raises `ArgumentError`.

  ## Losses

  `loss_counts/4` and `too_old/4` serve the two ways a destination loses
  events (§8.6, §9.6): retention deleting events it has not received yet,
  and events too old for its kind to accept. Both only count; neither loads
  an event.
  """
  import Ecto.Query, warn: false

  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditLog.Export
  alias Kanban.AuditLog.OrganizationScope
  alias Kanban.AuditLog.Query
  alias Kanban.Repo

  @typedoc "A position in commit order: `{txid, id}`."
  @type pair :: {non_neg_integer(), non_neg_integer()}

  @type counts :: %{
          events_waiting: non_neg_integer(),
          events_above_horizon: non_neg_integer(),
          oldest_waiting_at: DateTime.t() | nil
        }

  @type loss :: %{
          events: non_neg_integer(),
          first_at: DateTime.t() | nil,
          last_at: DateTime.t() | nil
        }

  @type too_old :: %{
          events: pos_integer(),
          first_at: DateTime.t(),
          last_at: DateTime.t(),
          last: pair(),
          last_inserted_at: DateTime.t()
        }

  @filter_defaults [not_before: nil, excluded_actions: [], include_personal_data: true]
  @batch_defaults [horizon: nil, batch_size: 500, max_bytes: 900_000, size_fun: nil]
  @personal_keys ["email", "ip"]

  defguardp is_pair(pair)
            when is_tuple(pair) and tuple_size(pair) == 2 and is_integer(elem(pair, 0)) and
                   is_integer(elem(pair, 1))

  # The horizon for one statement: the given value, or the oldest transaction
  # still running when the statement takes its snapshot.
  defmacrop horizon(value) do
    quote do
      fragment(
        "COALESCE(?, pg_snapshot_xmin(pg_current_snapshot())::text::bigint)",
        type(unquote(value), :integer)
      )
    end
  end

  @doc """
  The next batch of events after `cursor`, oldest in commit order first.

  Returns at most `:batch_size` events whose `txid` is below the horizon and
  whose (`txid`, `id`) sorts after `cursor`. The batch also stops before an
  event that would take the running total of `:size_fun` over `:max_bytes`,
  but always holds at least one event while one is waiting. `:size_fun`
  receives each event as it will be sent (redacted, personal data removed) and
  defaults to the byte size of its JSON-encoded `Export.row_map/1` plus one
  separator.

  The next cursor is `{txid, id}` of the batch's last event.
  """
  @spec next_batch(integer(), pair(), keyword()) :: [AuditEvent.t()]
  def next_batch(organization_id, cursor, opts \\ [])
      when is_integer(organization_id) and is_pair(cursor) do
    opts = options(opts, @filter_defaults ++ @batch_defaults)

    organization_id
    |> scoped(opts)
    |> after_pair(cursor)
    |> where([event: e], e.txid < horizon(^opts[:horizon]))
    |> in_commit_order()
    |> limit(^opts[:batch_size])
    |> load(organization_id, opts)
    |> within_bytes(opts[:max_bytes], opts[:size_fun] || (&encoded_size/1))
  end

  @doc """
  Re-reads exactly the events from `first` to `last`, both included, for a
  retry of a pending batch (§8.3), however many newer events have arrived.

  No horizon applies: every row up to `last` was below the horizon when the
  batch was cut, so the range can no longer change. No size limit applies
  either. The filters, redaction and personal-data removal are the same as for
  `next_batch/3`.
  """
  @spec read_range(integer(), pair(), pair(), keyword()) :: [AuditEvent.t()]
  def read_range(organization_id, first, last, opts \\ [])
      when is_integer(organization_id) and is_pair(first) and is_pair(last) do
    opts = options(opts, @filter_defaults)

    organization_id
    |> scoped(opts)
    |> from_pair(first)
    |> to_pair(last)
    |> in_commit_order()
    |> load(organization_id, opts)
  end

  @doc """
  How far a destination at `cursor` is behind (§13.1).

    * `events_waiting` - the events after `cursor`, with no horizon filter;
    * `events_above_horizon` - those of them not yet below the horizon;
    * `oldest_waiting_at` - the `inserted_at` of the oldest waiting event, or
      `nil` when none is waiting.

  The filters apply. A horizon held back by a long transaction therefore shows
  as waiting events, never as zero.
  """
  @spec waiting_counts(integer(), pair(), keyword()) :: counts()
  def waiting_counts(organization_id, cursor, opts \\ [])
      when is_integer(organization_id) and is_pair(cursor) do
    opts = options(opts, @filter_defaults ++ [horizon: nil])

    organization_id
    |> scoped(opts)
    |> exclude(:join)
    |> after_pair(cursor)
    |> select([event: e], %{
      events_waiting: count(e.id),
      events_above_horizon: filter(count(e.id), e.txid >= horizon(^opts[:horizon])),
      oldest_waiting_at: min(e.inserted_at)
    })
    |> Repo.one()
  end

  @doc """
  The `inserted_at` of the next event a destination at `cursor` can send:
  the first after `cursor` in commit order whose `txid` is below the horizon,
  or `nil` when none is. The filters apply.

  One indexed row, however long the backlog, so the sweep and the worker can
  ask it every minute and after every batch. Commit order is close to time
  order, so against minutes this is the age of the oldest sendable event;
  `waiting_counts/3` gives the exact oldest, at the cost of counting the whole
  backlog.
  """
  @spec next_waiting_at(integer(), pair(), keyword()) :: DateTime.t() | nil
  def next_waiting_at(organization_id, cursor, opts \\ [])
      when is_integer(organization_id) and is_pair(cursor) do
    opts = options(opts, @filter_defaults ++ [horizon: nil])

    organization_id
    |> scoped(opts)
    |> exclude(:join)
    |> after_pair(cursor)
    |> where([event: e], e.txid < horizon(^opts[:horizon]))
    |> in_commit_order()
    |> limit(1)
    |> select([event: e], e.inserted_at)
    |> Repo.one()
  end

  @doc """
  The events a destination at `cursor` has not received yet that were
  inserted strictly before `cutoff`, the events a retention purge at that
  cutoff deletes (§8.6): how many, and the first and last `inserted_at`
  (`nil` when there are none).

  No horizon applies: a purge deletes rows whatever their `txid`. The
  filters apply, so excluded actions and events before `not_before`, which
  the destination never sends, are never counted. `:through` (a pair)
  counts only events up to it, included, such as those of a pending batch.
  """
  @spec loss_counts(integer(), pair(), DateTime.t(), keyword()) :: loss()
  def loss_counts(organization_id, cursor, %DateTime{} = cutoff, opts \\ [])
      when is_integer(organization_id) and is_pair(cursor) do
    opts = options(opts, @filter_defaults ++ [through: nil])

    organization_id
    |> scoped(opts, until: cutoff)
    |> exclude(:join)
    |> after_pair(cursor)
    |> through(opts[:through])
    |> select([event: e], %{
      events: count(e.id),
      first_at: min(e.inserted_at),
      last_at: max(e.inserted_at)
    })
    |> Repo.one()
  end

  @doc """
  The events after `cursor`, below the horizon and in commit order, that
  come before the first one inserted at or after `threshold`: every
  waiting event when none is. They are too old for a destination whose
  kind accepts nothing inserted before `threshold` (§5.2), so its cursor
  moves past them and they are recorded as a gap.

  Returns how many, their first and last `inserted_at`, and the (`txid`,
  `id`) and `inserted_at` of the last one, or `nil` when the next waiting
  event is recent enough (or none is waiting). Only a prefix is ever
  returned: commit order is close to, but not exactly, time order, and the
  cursor can only move over a run of events with nothing left behind it.

  The horizon is read once, so every statement sees the same rows.
  """
  @spec too_old(integer(), pair(), DateTime.t(), keyword()) :: too_old() | nil
  def too_old(organization_id, cursor, %DateTime{} = threshold, opts \\ [])
      when is_integer(organization_id) and is_pair(cursor) do
    opts = options(opts, @filter_defaults ++ [horizon: nil])
    horizon = opts[:horizon] || current_horizon()

    base =
      organization_id
      |> scoped(opts)
      |> exclude(:join)
      |> after_pair(cursor)
      |> where([event: e], e.txid < ^horizon)

    prefix = before_pair(base, first_recent(base, threshold))
    too_old_prefix(prefix, last_of(prefix))
  end

  defp first_recent(query, threshold) do
    query
    |> where([event: e], e.inserted_at >= ^threshold)
    |> in_commit_order()
    |> limit(1)
    |> select([event: e], {e.txid, e.id})
    |> Repo.one()
  end

  defp last_of(query) do
    query
    |> order_by([event: e], desc: e.txid, desc: e.id)
    |> limit(1)
    |> select([event: e], %{txid: e.txid, id: e.id, inserted_at: e.inserted_at})
    |> Repo.one()
  end

  defp too_old_prefix(_prefix, nil), do: nil

  defp too_old_prefix(prefix, last) do
    prefix
    |> select([event: e], %{
      events: count(e.id),
      first_at: min(e.inserted_at),
      last_at: max(e.inserted_at)
    })
    |> Repo.one()
    |> Map.merge(%{last: {last.txid, last.id}, last_inserted_at: last.inserted_at})
  end

  defp current_horizon do
    %{rows: [[horizon]]} =
      Repo.query!("SELECT pg_snapshot_xmin(pg_current_snapshot())::text::bigint")

    horizon
  end

  defp options(opts, defaults) do
    opts = Keyword.validate!(opts, defaults)

    case Enum.find(opts, &(not valid_option?(&1))) do
      nil -> opts
      {key, _value} -> raise ArgumentError, "invalid value for option #{inspect(key)}"
    end
  end

  defp valid_option?({:not_before, value}), do: is_nil(value) or is_struct(value, DateTime)
  defp valid_option?({:excluded_actions, value}), do: is_list(value)
  defp valid_option?({:include_personal_data, value}), do: is_boolean(value)
  defp valid_option?({:horizon, value}), do: is_nil(value) or is_integer(value)
  defp valid_option?({:size_fun, value}), do: is_nil(value) or is_function(value, 1)
  defp valid_option?({:through, value}), do: is_nil(value) or is_pair(value)
  defp valid_option?({_limit, value}), do: is_integer(value) and value > 0

  # One Organization's events, with `organization_id` always an integer here
  # (the public guards), so Query never drops the scope.
  defp scoped(organization_id, opts, filters \\ []) do
    [organization_id: organization_id, since: opts[:not_before]]
    |> Kernel.++(filters)
    |> Query.events(:asc)
    |> exclude(:order_by)
    |> without_actions(opts[:excluded_actions])
  end

  defp without_actions(query, []), do: query

  defp without_actions(query, actions) do
    names = Enum.map(actions, &to_string/1)
    where(query, [event: e], e.action not in ^names)
  end

  # Row-value comparisons, so the order is the (txid, id) pair, never either
  # column alone.
  defp after_pair(query, {txid, id}) do
    where(
      query,
      [event: e],
      fragment("(?, ?) > (?, ?)", e.txid, e.id, type(^txid, :integer), type(^id, :integer))
    )
  end

  defp from_pair(query, {txid, id}) do
    where(
      query,
      [event: e],
      fragment("(?, ?) >= (?, ?)", e.txid, e.id, type(^txid, :integer), type(^id, :integer))
    )
  end

  defp to_pair(query, {txid, id}) do
    where(
      query,
      [event: e],
      fragment("(?, ?) <= (?, ?)", e.txid, e.id, type(^txid, :integer), type(^id, :integer))
    )
  end

  defp before_pair(query, nil), do: query

  defp before_pair(query, {txid, id}) do
    where(
      query,
      [event: e],
      fragment("(?, ?) < (?, ?)", e.txid, e.id, type(^txid, :integer), type(^id, :integer))
    )
  end

  defp through(query, nil), do: query
  defp through(query, pair), do: to_pair(query, pair)

  defp in_commit_order(query), do: order_by(query, [event: e], asc: e.txid, asc: e.id)

  defp load(query, organization_id, opts) do
    query
    |> Query.with_actor()
    |> Repo.all()
    |> OrganizationScope.redact_outside_actors(organization_id)
    |> personal_data(opts[:include_personal_data])
  end

  defp personal_data(events, true), do: events
  defp personal_data(events, false), do: Enum.map(events, &without_personal_data/1)

  defp without_personal_data(%AuditEvent{} = event) do
    %{
      event
      | ip: nil,
        actor_user: without_email(event.actor_user),
        metadata: without_personal_keys(event.metadata || %{})
    }
  end

  defp without_email(%{email: _email} = user), do: %{user | email: nil}
  defp without_email(user), do: user

  defp without_personal_keys(map) when is_map(map) and not is_struct(map) do
    map
    |> Map.drop(@personal_keys)
    |> Map.new(fn {key, value} -> {key, without_personal_keys(value)} end)
  end

  defp without_personal_keys(list) when is_list(list),
    do: Enum.map(list, &without_personal_keys/1)

  defp without_personal_keys(value), do: value

  # Keeps events while their running size stays within `max_bytes`, and always
  # the first one, so a batch is never empty while an event is waiting.
  defp within_bytes([], _max_bytes, _size_fun), do: []

  defp within_bytes([first | rest], max_bytes, size_fun) do
    {kept, _total} =
      Enum.reduce_while(rest, {[first], size_fun.(first)}, fn event, {kept, total} ->
        size = size_fun.(event)

        if total + size > max_bytes,
          do: {:halt, {kept, total}},
          else: {:cont, {[event | kept], total + size}}
      end)

    Enum.reverse(kept)
  end

  defp encoded_size(event) do
    event
    |> Export.row_map()
    |> Jason.encode_to_iodata!()
    |> IO.iodata_length()
    |> Kernel.+(1)
  end
end
