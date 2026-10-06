defmodule Kanban.AuditLog do
  @moduledoc """
  Structured audit trail for security-relevant events.

  Each event is emitted three ways from a single call:

    * a `:telemetry` event `[:kanban, :audit, <action>]` (measurement
      `%{count: 1}`, metadata the sanitized fields) — the monitoring/alerting
      bus, and what tests attach to;
    * a structured `Logger.info("security_audit", ...)` line carrying the same
      fields as Logger metadata (never string-interpolated); and
    * one row in the append-only `audit_events` table
      (`Kanban.AuditLog.AuditEvent`), so events can be queried, exported and
      retained. A database trigger rejects every edit of a stored row (except
      the foreign-key cascade that nulls `actor_user_id` when its user is
      deleted), every `TRUNCATE`, and every delete outside the retention purge.

  Callers pass an action atom and a keyword list of context. Known-sensitive
  keys (passwords, raw tokens, secrets) are dropped defensively before anything
  is emitted or stored, and IP tuples are formatted to strings, so a raw
  credential can never reach the log, the telemetry bus or the table even if a
  caller passes one by mistake.

  Persistence never crashes the caller: if the insert fails (database
  unavailable, constraint violation) the failure is logged and `event/2` still
  returns `:ok`. Inside an open transaction the insert runs under a savepoint,
  so a failed audit insert cannot abort the caller's transaction.

  ## Example

      Kanban.AuditLog.event(:login_failed, email: email, ip: conn.remote_ip)
      Kanban.AuditLog.event(:api_token_created, user_id: user.id, board_id: board.id, token_id: token.id)
  """
  import Ecto.Query, warn: false

  alias Kanban.AuditLog.AuditEvent
  alias Kanban.Repo

  require Logger

  @telemetry_prefix [:kanban, :audit]

  # A key is dropped when its name CONTAINS any of these substrings, so
  # credential-shaped keys the original exact-match list never anticipated
  # (:reset_token, :api_key, :refresh_token, :session_token, :otp_secret, …)
  # are redacted too, honoring the moduledoc's never-log guarantee (D159).
  @sensitive_substrings ~w(password token secret authorization key otp)

  # Keys ending in `_id` are database identifiers (user_id, board_id,
  # token_id — a row id, not the token value), so they are exempt from the
  # substring rule even when the substring would otherwise match.
  @id_suffix "_id"

  # Longest string stored for any one metadata value; longer values are cut.
  @max_value_length 2_000
  @max_ip_length 255
  @max_bigint 9_223_372_036_854_775_807

  @default_limit 100

  @doc """
  Emit a security audit event. `action` is a stable atom (e.g. `:login_failed`);
  `metadata` is a keyword list of non-sensitive context.
  """
  @spec event(atom(), keyword()) :: :ok
  def event(action, metadata \\ []) when is_atom(action) and is_list(metadata) do
    clean = sanitize(metadata)

    :telemetry.execute(@telemetry_prefix ++ [action], %{count: 1}, Map.new(clean))
    Logger.info("security_audit", [audit_event: action] ++ clean)

    persist(action, clean)

    :ok
  end

  @doc """
  Lists stored audit events, newest first by default.

  `filters`:

    * `:action` — only events with this action (atom or string).
    * `:actor_user_id` — only events whose actor is this user id.
    * `:since` / `:until` — only events inserted at or after / before this
      `DateTime`.

  `opts`:

    * `:limit` — maximum rows returned (default #{@default_limit}).
    * `:order` — `:desc` (default) or `:asc` by insertion time.
  """
  @spec list_events(keyword(), keyword()) :: [AuditEvent.t()]
  def list_events(filters \\ [], opts \\ []) do
    filters
    |> events_query(Keyword.get(opts, :order, :desc))
    |> limit(^Keyword.get(opts, :limit, @default_limit))
    |> Repo.all()
  end

  @doc """
  Streams stored audit events matching `filters` (see `list_events/2`), for
  exports too large to load at once.

  Like every `Repo.stream/2`, the stream must be enumerated inside a
  `Repo.transaction/2`. `opts` accepts `:order` (default `:asc`, oldest first)
  and `:max_rows` (rows fetched per round trip, default 500).
  """
  @spec stream_events(keyword(), keyword()) :: Enum.t()
  def stream_events(filters \\ [], opts \\ []) do
    filters
    |> events_query(Keyword.get(opts, :order, :asc))
    |> Repo.stream(max_rows: Keyword.get(opts, :max_rows, 500))
  end

  defp events_query(filters, order) when order in [:asc, :desc] do
    query = Enum.reduce(filters, from(e in AuditEvent), &apply_filter/2)
    order_by(query, [e], [{^order, e.inserted_at}, {^order, e.id}])
  end

  defp apply_filter({:action, action}, query) when is_atom(action) and not is_nil(action),
    do: apply_filter({:action, Atom.to_string(action)}, query)

  defp apply_filter({:action, action}, query) when is_binary(action),
    do: where(query, [e], e.action == ^action)

  defp apply_filter({:actor_user_id, id}, query) when is_integer(id),
    do: where(query, [e], e.actor_user_id == ^id)

  defp apply_filter({:since, %DateTime{} = since}, query),
    do: where(query, [e], e.inserted_at >= ^since)

  defp apply_filter({:until, %DateTime{} = until}, query),
    do: where(query, [e], e.inserted_at < ^until)

  defp apply_filter({_key, nil}, query), do: query

  defp sanitize(metadata) do
    metadata
    |> Enum.reject(fn {key, _value} -> sensitive_key?(key) end)
    |> Enum.map(&format_pair/1)
  end

  defp sensitive_key?(key) do
    name = to_string(key)

    not String.ends_with?(name, @id_suffix) and
      Enum.any?(@sensitive_substrings, &String.contains?(name, &1))
  end

  # Format IP address tuples (conn.remote_ip / peer address) to a string.
  defp format_pair({key, value}) when is_tuple(value) and tuple_size(value) in [4, 8] do
    case :inet.ntoa(value) do
      {:error, _} -> {key, "unknown"}
      charlist -> {key, to_string(charlist)}
    end
  end

  defp format_pair(pair), do: pair

  # --- persistence -----------------------------------------------------------

  # Stores the already-sanitized pairs, never the raw metadata. Every failure —
  # an invalid changeset, a Postgres error, a missing sandbox owner in tests, a
  # checkout timeout — is logged (by exception type only, never the values) and
  # swallowed, so auditing can never crash or roll back the caller.
  defp persist(action, clean) do
    attrs = %{
      action: action |> Atom.to_string() |> clean_string(),
      actor_user_id: actor_user_id(clean),
      ip: ip(clean),
      metadata: json_safe_map(clean)
    }

    case insert_event(attrs) do
      {:ok, _event} ->
        :ok

      {:error, changeset} ->
        log_persist_failure(action, {:invalid, Keyword.keys(changeset.errors)})
    end
  catch
    kind, reason -> log_persist_failure(action, failure_reason(kind, reason))
  end

  # Only the exception's type (or the throw/exit kind) is logged — an exception
  # message can quote the values that failed to insert.
  defp failure_reason(:error, %{__exception__: true, __struct__: module}), do: module
  defp failure_reason(kind, _reason), do: kind

  defp insert_event(attrs) do
    attrs
    |> AuditEvent.insert_changeset()
    |> Repo.insert(insert_opts())
    |> retry_without_actor(attrs)
  end

  # A user_id with no users row (stale, or the user deleted concurrently) fails
  # the actor foreign key. Losing the whole event for that would defeat the
  # audit trail, so the row is stored once more without the actor link — the
  # id itself is still kept in the metadata.
  defp retry_without_actor({:error, %Ecto.Changeset{errors: errors}} = error, attrs) do
    if attrs.actor_user_id != nil and Keyword.has_key?(errors, :actor_user_id),
      do: insert_event(%{attrs | actor_user_id: nil}),
      else: error
  end

  defp retry_without_actor(result, _attrs), do: result

  # Inside a caller's transaction a failed statement would poison it; a
  # savepoint confines the failure to the audit insert. Outside a transaction
  # Postgrex rejects savepoint mode, so the default is used.
  defp insert_opts do
    if Repo.in_transaction?(), do: [mode: :savepoint], else: []
  end

  # The action atom and the failure type are code-defined, never caller data,
  # so they are safe to put in the message, where the default console format
  # (which prints only a few metadata keys) will show them.
  defp log_persist_failure(action, reason) do
    Logger.error("security_audit_persist_failed action=#{action} reason=#{inspect(reason)}")
  end

  defp actor_user_id(clean) do
    case Keyword.get(clean, :user_id) do
      id when is_integer(id) and id > 0 and id <= @max_bigint -> id
      _ -> nil
    end
  end

  defp ip(clean) do
    case Keyword.get(clean, :ip) do
      ip when is_binary(ip) -> ip |> json_safe() |> String.slice(0, @max_ip_length)
      _ -> nil
    end
  end

  # Converts a key/value enumerable into a map jsonb can store: string keys,
  # credential-shaped keys dropped at every depth (the top level was already
  # sanitized), and every value made JSON-encodable.
  defp json_safe_map(pairs) do
    for {key, value} <- pairs,
        name = key_name(key),
        not sensitive_key?(name),
        into: %{},
        do: {name, json_safe(value)}
  end

  defp key_name(key) when is_binary(key), do: json_safe(key)
  defp key_name(key) when is_atom(key), do: key |> Atom.to_string() |> clean_string()
  defp key_name(key), do: key |> inspect() |> clean_string()

  defp json_safe(value) when is_nil(value) or is_boolean(value) or is_number(value), do: value
  defp json_safe(value) when is_atom(value), do: value |> Atom.to_string() |> clean_string()

  defp json_safe(value) when is_binary(value) do
    if String.valid?(value), do: clean_string(value), else: value |> inspect() |> clean_string()
  end

  defp json_safe(%module{} = struct) do
    # A struct's fields could carry anything (a schema's password hash, a
    # token), so only types with a deliberate string form are expanded; any
    # other struct is recorded by its type alone.
    if String.Chars.impl_for(struct),
      do: struct |> to_string() |> clean_string(),
      else: "%#{inspect(module)}{}"
  end

  defp json_safe(map) when is_map(map), do: json_safe_map(map)

  defp json_safe(list) when is_list(list), do: json_safe_list(list)

  # Tuples, pids, references, functions and ports.
  defp json_safe(other), do: other |> inspect() |> clean_string()

  defp json_safe_list(list) do
    cond do
      List.improper?(list) -> list |> inspect() |> clean_string()
      list != [] and Keyword.keyword?(list) -> json_safe_map(list)
      true -> Enum.map(list, &json_safe/1)
    end
  end

  # Postgres rejects NUL in text and jsonb (22P05), so a NUL anywhere would make
  # the insert fail and silently drop the row — a caller-controlled value could
  # suppress its own audit record. Replace it, then cap the length.
  defp clean_string(string) do
    string
    |> String.replace(<<0>>, "\uFFFD")
    |> String.slice(0, @max_value_length)
  end
end
