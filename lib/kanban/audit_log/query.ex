defmodule Kanban.AuditLog.Query do
  @moduledoc """
  Composable Ecto queries over `audit_events`, and the opaque keyset cursor the
  admin viewer pages with.

  Pure query building — nothing here touches `Kanban.Repo`; the public entry
  points live in `Kanban.AuditLog`. Every query left-joins the actor user (a
  `belongs_to`, so the join can never multiply rows and `LIMIT` stays exact);
  `with_actor/1` preloads it from that join, so rendering a page or an export
  never issues N+1 queries.

  Filters are applied from a keyword list whose values must already be parsed
  into their final types (see `Kanban.AuditLog.Filters.parse/1`); a key whose
  value is `nil` is ignored.
  """
  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.AuditLog.AuditEvent

  @max_bigint 9_223_372_036_854_775_807

  # The same bound `Kanban.AuditLog.Filters` applies to dates: DateTime accepts
  # years Postgres cannot bind (before 4713 BC), which would make the query raise.
  @year_range 1..9999

  @doc """
  Builds the filtered, ordered event query. `order` is `:desc` (newest first)
  or `:asc`; ties on `inserted_at` are broken by `id` so the order is total,
  which the keyset cursor relies on.
  """
  @spec events(keyword(), :asc | :desc) :: Ecto.Query.t()
  def events(filters, order) when order in [:asc, :desc] do
    base =
      from(e in AuditEvent,
        as: :event,
        left_join: u in User,
        as: :actor,
        on: u.id == e.actor_user_id
      )

    filters
    |> Enum.reduce(base, &filter/2)
    |> order_by([e], [{^order, e.inserted_at}, {^order, e.id}])
  end

  @doc """
  Preloads each event's actor user from the join `events/2` already made, so a
  page or export renders actors without N+1 queries. Not usable with
  `Repo.stream/2`, which does not support preloads.
  """
  @spec with_actor(Ecto.Query.t()) :: Ecto.Query.t()
  def with_actor(query), do: preload(query, [actor: u], actor_user: u)

  defp filter({_key, nil}, query), do: query

  defp filter({:action, action}, query) when is_atom(action),
    do: filter({:action, Atom.to_string(action)}, query)

  defp filter({:action, action}, query) when is_binary(action),
    do: where(query, [e], e.action == ^action)

  defp filter({:actor_user_id, id}, query) when is_integer(id),
    do: where(query, [e], e.actor_user_id == ^id)

  # Matches the actor's account email (citext, so case-insensitive) OR an
  # `email` recorded in the event metadata — login_failed and
  # password_reset_requested have no actor, only the attempted email. Exact
  # match only: no LIKE, so user input can never act as a wildcard.
  defp filter({:actor_email, email}, query) when is_binary(email) do
    where(
      query,
      [event: e, actor: u],
      u.email == ^email or fragment("lower(?->>'email') = lower(?)", e.metadata, ^email)
    )
  end

  defp filter({:since, %DateTime{} = since}, query),
    do: where(query, [e], e.inserted_at >= ^since)

  defp filter({:until, %DateTime{} = until}, query),
    do: where(query, [e], e.inserted_at < ^until)

  # Keyset pagination for a newest-first listing: rows strictly older than the
  # cursor row, with `id` breaking ties on identical timestamps.
  defp filter({:cursor, {%DateTime{} = at, id}}, query) when is_integer(id) do
    where(query, [e], e.inserted_at < ^at or (e.inserted_at == ^at and e.id < ^id))
  end

  @doc """
  Encodes the position of `event` as an opaque, URL-safe cursor.
  """
  @spec encode_cursor(AuditEvent.t()) :: String.t()
  def encode_cursor(%AuditEvent{inserted_at: %DateTime{} = at, id: id}) do
    Base.url_encode64("#{DateTime.to_unix(at, :microsecond)}:#{id}", padding: false)
  end

  @doc """
  Decodes a cursor produced by `encode_cursor/1` into `{inserted_at, id}`.
  Anything malformed or tampered with — including a timestamp outside years
  1..9999, which the database cannot bind — returns `nil` (callers fall back
  to the first page); it never raises.
  """
  @spec decode_cursor(term()) :: {DateTime.t(), pos_integer()} | nil
  def decode_cursor(cursor) when is_binary(cursor) and byte_size(cursor) <= 64 do
    case Base.url_decode64(cursor, padding: false) do
      {:ok, decoded} -> decoded |> String.split(":") |> cursor_parts()
      :error -> nil
    end
  end

  def decode_cursor(_cursor), do: nil

  defp cursor_parts([usec_text, id_text]) do
    with {:ok, at} <- cursor_timestamp(usec_text),
         {:ok, id} <- cursor_id(id_text) do
      {at, id}
    else
      :error -> nil
    end
  end

  defp cursor_parts(_parts), do: nil

  defp cursor_timestamp(usec_text) do
    with {usec, ""} <- Integer.parse(usec_text),
         {:ok, %DateTime{year: year} = at} when year in @year_range <-
           DateTime.from_unix(usec, :microsecond) do
      {:ok, at}
    else
      _ -> :error
    end
  end

  defp cursor_id(id_text) do
    case Integer.parse(id_text) do
      {id, ""} when id > 0 and id <= @max_bigint -> {:ok, id}
      _ -> :error
    end
  end
end
