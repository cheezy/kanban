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
      Where the migration could harden it (see `Kanban.AuditLog.Hardening`),
      the table belongs to a separate owner role, so the application cannot
      disable that trigger.

  ## Retention

  `purge_before/1` is the sanctioned way to remove rows. It calls the database
  function `audit_events_purge`, which refuses a cutoff newer than the
  retention floor (90 days) and removes only rows strictly older than the
  cutoff — the floor is enforced in the database, so even a compromised
  application cannot erase recent history through it. In hardened mode (see
  `Kanban.AuditLog.Hardening.Purge`) that function belongs to the owner role
  and runs with its rights, and the trigger admits a delete only from the
  owner of `audit_events`: the transaction-local `kanban.audit_purge` flag is
  **not** the control there and is ignored, so the purge function is the only
  path the application has. In degraded mode (a database the migration could
  not harden) the function belongs to the application role and the flag-based
  trigger stays: the function sets the flag itself, so `purge_before/1` works
  in both modes, but the trigger also admits any other delete made with the
  flag set.

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
  alias Kanban.AuditLog.Export
  alias Kanban.AuditLog.Query
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
  @default_page_size 50
  @max_page_size 200
  @export_batch_size 500

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
  Lists stored audit events, newest first by default, with each event's actor
  user preloaded (`nil` when there is none or it was deleted).

  `filters`:

    * `:action` — only events with this action (atom or string).
    * `:actor_user_id` — only events whose actor is this user id.
    * `:actor_email` — only events whose actor's email, or whose recorded
      `email` metadata, equals this (case-insensitive, exact).
    * `:since` / `:until` — only events inserted at or after / before this
      `DateTime`.
    * `:cursor` — a decoded keyset cursor `{inserted_at, id}`; only events
      older than that position (meaningful with the default `:desc` order).

  `opts`:

    * `:limit` — maximum rows returned (default #{@default_limit}).
    * `:order` — `:desc` (default) or `:asc` by insertion time.
  """
  @spec list_events(keyword(), keyword()) :: [AuditEvent.t()]
  def list_events(filters \\ [], opts \\ []) do
    filters
    |> Query.events(Keyword.get(opts, :order, :desc))
    |> Query.with_actor()
    |> limit(^Keyword.get(opts, :limit, @default_limit))
    |> Repo.all()
  end

  @doc """
  One newest-first page of events for the admin viewer, paginated by keyset
  (never by offset).

  Takes the same `filters` as `list_events/2`. `opts`:

    * `:cursor` — a decoded cursor (see `Kanban.AuditLog.Query.decode_cursor/1`);
      `nil` starts at the newest event.
    * `:limit` — page size, clamped to 1..#{@max_page_size} (default #{@default_page_size}).

  Returns `%{entries: events, next_cursor: encoded | nil}`; `next_cursor` is
  `nil` on the last page.
  """
  @spec list_events_page(keyword(), keyword()) :: %{
          entries: [AuditEvent.t()],
          next_cursor: String.t() | nil
        }
  def list_events_page(filters \\ [], opts \\ []) do
    page_size = opts |> Keyword.get(:limit, @default_page_size) |> clamp_page_size()

    rows =
      filters
      |> Keyword.put(:cursor, Keyword.get(opts, :cursor))
      |> list_events(limit: page_size + 1)

    {entries, rest} = Enum.split(rows, page_size)
    next_cursor = if rest != [], do: entries |> List.last() |> Query.encode_cursor()

    %{entries: entries, next_cursor: next_cursor}
  end

  @doc """
  The distinct action names stored so far, alphabetically — the choices for
  the viewer's action filter.
  """
  @spec list_actions() :: [String.t()]
  def list_actions do
    from(e in AuditEvent, distinct: true, select: e.action, order_by: e.action)
    |> Repo.all()
  end

  @doc """
  A lazy stream of export chunks (iodata) for every event matching `filters`,
  newest first, as `:csv` (header line then rows) or `:json` (one array of
  objects).

  Events are fetched in keyset batches of `:batch_size` (default
  #{@export_batch_size}) as the stream is consumed, so an export never loads
  the whole table and holds no transaction or connection while the response
  is being sent. Events inserted after the export starts are newer than its
  first batch and are therefore not included.
  """
  @spec export_stream(keyword(), :csv | :json, keyword()) :: Enumerable.t()
  def export_stream(filters, format, opts \\ []) when format in [:csv, :json] do
    batch_size = Keyword.get(opts, :batch_size, @export_batch_size)

    {:after, nil}
    |> Stream.unfold(fn
      :done -> nil
      {:after, cursor} -> next_export_batch(filters, cursor, batch_size)
    end)
    |> Export.encode_stream(format)
  end

  defp next_export_batch(filters, cursor, batch_size) do
    case list_events(Keyword.put(filters, :cursor, cursor), limit: batch_size) do
      [] -> nil
      batch when length(batch) < batch_size -> {batch, :done}
      batch -> {batch, {:after, batch |> List.last() |> keyset_position()}}
    end
  end

  defp keyset_position(%AuditEvent{inserted_at: at, id: id}), do: {at, id}

  @doc """
  Streams stored audit events matching `filters` (see `list_events/2`), for
  exports too large to load at once. The actor is not preloaded (streams do not
  support preloads).

  Like every `Repo.stream/2`, the stream must be enumerated inside a
  `Repo.transaction/2`. `opts` accepts `:order` (default `:asc`, oldest first)
  and `:max_rows` (rows fetched per round trip, default 500).
  """
  @spec stream_events(keyword(), keyword()) :: Enum.t()
  def stream_events(filters \\ [], opts \\ []) do
    filters
    |> Query.events(Keyword.get(opts, :order, :asc))
    |> Repo.stream(max_rows: Keyword.get(opts, :max_rows, 500))
  end

  defp clamp_page_size(size) when is_integer(size), do: size |> max(1) |> min(@max_page_size)
  defp clamp_page_size(_size), do: @default_page_size

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

  # --- retention -------------------------------------------------------------

  @purge_refused_code Kanban.AuditLog.Hardening.Purge.cutoff_too_recent_code()

  @doc """
  Removes every stored event inserted strictly before `cutoff` through the
  database purge function, returning `{:ok, removed_count}`.

  Returns `{:error, :cutoff_too_recent}` when the function refuses the cutoff
  because it is newer than the retention floor (90 days ago). The cutoff is
  passed as a bound parameter. Any other failure raises: purge is an operator
  maintenance call, not a request path, so a silent failure would hide lost
  retention. Inside an open transaction the call runs under a savepoint, so a
  refusal does not abort the caller's transaction.
  """
  @spec purge_before(DateTime.t()) :: {:ok, non_neg_integer()} | {:error, :cutoff_too_recent}
  def purge_before(%DateTime{} = cutoff) do
    case Repo.query("SELECT audit_events_purge($1)", [cutoff], statement_opts()) do
      {:ok, %{rows: [[removed]]}} ->
        {:ok, removed}

      {:error, %Postgrex.Error{postgres: %{pg_code: @purge_refused_code}}} ->
        {:error, :cutoff_too_recent}

      {:error, error} ->
        raise error
    end
  end

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
    |> Repo.insert(statement_opts())
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
  # savepoint confines the failure to the audit statement. Outside a
  # transaction Postgrex rejects savepoint mode, so the default is used.
  defp statement_opts do
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
