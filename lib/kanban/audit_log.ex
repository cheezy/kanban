defmodule Kanban.AuditLog do
  @moduledoc """
  Structured audit trail for security-relevant events.

  Each event is emitted three ways from a single call:

    * a `:telemetry` event `[:kanban, :audit, <action>]`, emitted through
      `Kanban.Telemetry` (measurement `%{count: 1}`, metadata the sanitized
      fields minus `email`, `ip` and `filters`) — the monitoring/alerting bus,
      and what tests attach to. Telemetry can leave the app, so it never
      carries personal data; the log line and the stored row below keep those
      fields, because they are the compliance record;
    * a structured `Logger.info("security_audit", ...)` line carrying the same
      fields as Logger metadata (never string-interpolated); and
    * one row in the append-only `audit_events` table
      (`Kanban.AuditLog.AuditEvent`), so events can be queried, exported and
      retained. A database trigger rejects every edit of a stored row (except
      the foreign-key cascade that nulls `actor_user_id` when its user is
      deleted), every `TRUNCATE`, and every delete outside the retention purge.
      A positive integer `organization_id` in the context that names an
      existing Organization is also stored in its own column, which scopes the
      org-admin audit log at `/org/audit`; an out-of-range or stale id stays
      in the metadata only. When the event also has an actor, whether that
      actor was a member of the Organization at that moment is stored too,
      and the org-admin log redacts from it (see
      `Kanban.AuditLog.OrganizationScope`).
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

  ## Related modules

  This module writes, lists and purges events. Building blocks live beside it:
  `Kanban.AuditLog.Query` (query builders and keyset cursors),
  `Kanban.AuditLog.Filters` (request-param parsing),
  `Kanban.AuditLog.OrganizationScope` (org-admin redaction) and
  `Kanban.AuditLog.Export` (keyset-batched CSV/JSON exports, with the total
  row cap). `export_stream/3` and `export_truncated?/3` are delegated to
  `Kanban.AuditLog.Export`, so callers use this module's API only.

  ## Example

      Kanban.AuditLog.event(:login_failed, email: email, ip: conn.remote_ip)
      Kanban.AuditLog.event(:api_token_created, user_id: user.id, board_id: board.id, token_id: token.id)
  """
  import Ecto.Query, warn: false

  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditLog.Export
  alias Kanban.AuditLog.OrganizationScope
  alias Kanban.AuditLog.Query
  alias Kanban.Repo

  require Logger

  @telemetry_prefix [:kanban, :audit]

  # Personal data kept in the audit row and log line but never sent to
  # telemetry. `filters` (audit-log exports) can contain an actor email.
  @telemetry_omitted_keys [:email, :ip, :filters]

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
  @default_stream_batch_size 500

  @doc """
  Emit a security audit event. `action` is a stable atom (e.g. `:login_failed`);
  `metadata` is a keyword list of non-sensitive context.
  """
  @spec event(atom(), keyword()) :: :ok
  def event(action, metadata \\ []) when is_atom(action) and is_list(metadata) do
    clean = sanitize(metadata)

    emit_telemetry(action, clean)
    Logger.info("security_audit", [audit_event: action] ++ clean)

    persist(action, clean)

    :ok
  end

  # strict: false because event/2 must never crash its caller: an action or
  # key missing from Kanban.Telemetry.Catalog is logged and dropped instead.
  defp emit_telemetry(action, clean) do
    metadata = Keyword.drop(clean, @telemetry_omitted_keys)

    Kanban.Telemetry.emit(@telemetry_prefix ++ [action], %{count: 1}, metadata, strict: false)
  end

  @doc """
  Lists stored audit events, newest first by default, with each event's actor
  user preloaded (`nil` when there is none or it was deleted).

  `filters`:

    * `:action` — only events with this action (atom or string).
    * `:actor_user_id` — only events whose actor is this user id.
    * `:organization_id` — only events linked to this Organization id. Callers
      force it from the signed-in org-admin's membership; it is never parsed
      from request params (see `Kanban.AuditLog.Filters`).
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

  @doc "See `Kanban.AuditLog.Export.export_truncated?/3`."
  defdelegate export_truncated?(filters, max_rows, pending), to: Export

  @doc """
  One newest-first page of events for the admin viewer, paginated by keyset
  (never by offset).

  Takes the same `filters` as `list_events/2`. `opts`:

    * `:cursor` — a decoded cursor (see `Kanban.AuditLog.Query.decode_cursor/1`);
      `nil` starts at the newest event.
    * `:limit` — page size, clamped to 1..#{@max_page_size} (default #{@default_page_size}).
    * `:redact_actors_outside` — an Organization id. Events whose actor is not
      a member of that Organization lose the actor's identity and IP (see
      `Kanban.AuditLog.OrganizationScope.redact_outside_actors/2`). The org
      viewer passes it; the site-admin viewer does not.

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

    %{entries: redact(entries, opts), next_cursor: next_cursor}
  end

  @doc """
  The distinct action names stored so far, alphabetically — the choices for
  the viewer's action filter.

  `filters` takes the same keys as `list_events/2`; the org viewer passes
  `organization_id:` so its filter lists only that Organization's actions.
  """
  @spec list_actions(keyword()) :: [String.t()]
  def list_actions(filters \\ []) do
    filters
    |> Query.actions()
    |> Repo.all()
  end

  @doc """
  A lazy stream of CSV or JSON export chunks for every event matching
  `filters`, capped at the TOTAL `:max_rows`. See
  `Kanban.AuditLog.Export.export_stream/3` for the options.
  """
  defdelegate export_stream(filters, format, opts \\ []), to: Export

  defp redact(events, opts) do
    case Keyword.get(opts, :redact_actors_outside) do
      nil -> events
      organization_id -> OrganizationScope.redact_outside_actors(events, organization_id)
    end
  end

  @doc """
  Streams stored audit events matching `filters` (see `list_events/2`), for
  exports too large to load at once. The actor is not preloaded (streams do not
  support preloads).

  Like every `Repo.stream/2`, the stream must be enumerated inside a
  `Repo.transaction/2`. `opts` (any other key raises `ArgumentError`):

    * `:order` — `:asc` (default, oldest first) or `:desc`.
    * `:batch_size` — rows fetched per round trip (default
      #{@default_stream_batch_size}). It is deliberately not called
      `:max_rows`: `export_stream/3` uses that name for a TOTAL row cap, and
      the strict option check makes a `:max_rows` copied from there fail
      loudly here instead of being ignored.
  """
  @spec stream_events(keyword(), keyword()) :: Enum.t()
  def stream_events(filters \\ [], opts \\ []) do
    opts = Keyword.validate!(opts, order: :asc, batch_size: @default_stream_batch_size)

    filters
    |> Query.events(opts[:order])
    |> Repo.stream(max_rows: opts[:batch_size])
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

  @doc """
  Removes up to `batch_limit` events of one Organization (or, for `nil`, events
  with no Organization) inserted strictly before `cutoff`, under the same
  90-day floor as `purge_before/1`. See
  `Kanban.AuditLog.Retention.purge_organization_before/3`.
  """
  defdelegate purge_organization_before(organization_id, cutoff, batch_limit),
    to: Kanban.AuditLog.Retention

  # --- persistence -----------------------------------------------------------

  # Stores the already-sanitized pairs, never the raw metadata. Every failure —
  # an invalid changeset, a Postgres error, a missing sandbox owner in tests, a
  # checkout timeout — is logged (by exception type only, never the values) and
  # swallowed, so auditing can never crash or roll back the caller.
  defp persist(action, clean) do
    actor_user_id = bounded_id(clean, :user_id)
    organization_id = bounded_id(clean, :organization_id)

    attrs = %{
      action: action |> Atom.to_string() |> clean_string(),
      actor_user_id: actor_user_id,
      organization_id: organization_id,
      actor_in_organization:
        OrganizationScope.actor_member?(
          actor_user_id,
          organization_id,
          statement_opts()
        ),
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
    |> retry_without_stale_link(attrs)
  end

  @linked_ids [:actor_user_id, :organization_id]

  # A user_id with no users row (stale, or the user deleted concurrently) fails
  # the actor foreign key, and an organization_id with no organizations row
  # fails the Organization one. Losing the whole event for that would defeat
  # the audit trail, so the row is stored once more without the failing link —
  # the id itself is still kept in the metadata. Postgres reports one failed
  # constraint per insert, so a row with both links stale is retried twice.
  defp retry_without_stale_link({:error, %Ecto.Changeset{errors: errors}} = error, attrs) do
    case Enum.find(@linked_ids, &(attrs[&1] != nil and Keyword.has_key?(errors, &1))) do
      nil -> error
      field -> insert_event(Map.put(attrs, field, nil))
    end
  end

  defp retry_without_stale_link(result, _attrs), do: result

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

  # A positive integer that fits a bigint column, else nil. Used for the actor
  # (`:user_id`) and the Organization (`:organization_id`) links.
  defp bounded_id(clean, key) do
    case Keyword.get(clean, key) do
      id when is_integer(id) and id > 0 and id <= @max_bigint -> id
      _ -> nil
    end
  end

  # The ip column holds only a parseable address, normalized ("2001:DB8::1"
  # becomes "2001:db8::1"); any other string is stored as "unknown", the same
  # as an unformattable tuple. The value as given stays in the metadata.
  defp ip(clean) do
    case Keyword.get(clean, :ip) do
      ip when is_binary(ip) -> normalize_ip(ip)
      _ -> nil
    end
  end

  defp normalize_ip(text) do
    with true <- byte_size(text) <= @max_ip_length and String.valid?(text),
         {:ok, address} <- text |> String.trim() |> String.to_charlist() |> :inet.parse_address() do
      address |> :inet.ntoa() |> to_string()
    else
      _invalid -> "unknown"
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
