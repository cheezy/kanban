defmodule Kanban.AuditLog do
  @moduledoc """
  Structured audit trail for security-relevant events.

  Each event is emitted two ways from a single call:

    * a `:telemetry` event `[:kanban, :audit, <action>]` (measurement
      `%{count: 1}`, metadata the sanitized fields) — the monitoring/alerting
      bus, and what tests attach to; and
    * a structured `Logger.info("security_audit", ...)` line carrying the same
      fields as Logger metadata (never string-interpolated).

  Log-based only — no database table. Callers pass an action atom and a keyword
  list of context. Known-sensitive keys (passwords, raw tokens, secrets) are
  dropped defensively before anything is emitted, and IP tuples are formatted to
  strings, so a raw credential can never reach the log or the telemetry bus even
  if a caller passes one by mistake.

  ## Example

      Kanban.AuditLog.event(:login_failed, email: email, ip: conn.remote_ip)
      Kanban.AuditLog.event(:api_token_created, user_id: user.id, board_id: board.id, token_id: token.id)
  """
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

  @doc """
  Emit a security audit event. `action` is a stable atom (e.g. `:login_failed`);
  `metadata` is a keyword list of non-sensitive context.
  """
  @spec event(atom(), keyword()) :: :ok
  def event(action, metadata \\ []) when is_atom(action) and is_list(metadata) do
    clean = sanitize(metadata)

    :telemetry.execute(@telemetry_prefix ++ [action], %{count: 1}, Map.new(clean))
    Logger.info("security_audit", [audit_event: action] ++ clean)

    :ok
  end

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
end
