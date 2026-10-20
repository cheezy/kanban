defmodule KanbanWeb.RequestLog do
  @moduledoc """
  Keeps plaintext tokens out of the request log.

  Phoenix logs every request as `GET <request_path>` and `Sent <status> in
  <duration>` from the endpoint's `Plug.Telemetry` events. On a route that
  carries a secret token in its path (`KanbanWeb.TokenPaths`, such as
  `/invitations/:token`) that line would write the token to the log, which
  production keeps at `:info`.

  The endpoint's `Plug.Telemetry` takes `log: {KanbanWeb.RequestLog, :level,
  []}`, so Phoenix skips both lines for those routes, and `attach/0` (called
  when `KanbanWeb.Telemetry` starts) logs them instead with the token
  replaced by `[FILTERED]`. Every other request is logged by Phoenix at
  `:info`, as before.
  """

  alias KanbanWeb.TokenPaths

  require Logger

  @handler_id {__MODULE__, :redacted_request_lines}
  @events [[:phoenix, :endpoint, :start], [:phoenix, :endpoint, :stop]]
  @mark "[FILTERED]"

  @doc """
  The level Phoenix logs `conn`'s request lines at: `false` (not logged by
  Phoenix) for a token route, `:info` otherwise.
  """
  @spec level(Plug.Conn.t()) :: :info | false
  def level(%Plug.Conn{request_path: path}) do
    if TokenPaths.token_path?(path), do: false, else: :info
  end

  @doc """
  Attaches the handler that logs a token route's request lines with the token
  redacted. Attaching again is a no-op.
  """
  @spec attach() :: :ok
  def attach do
    case :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  # Public only so :telemetry can call it without a local-function warning.
  def handle_event([:phoenix, :endpoint, :start], _measurements, %{conn: conn}, _config) do
    if TokenPaths.token_path?(conn.request_path) do
      Logger.info(fn -> [conn.method, ?\s, TokenPaths.redact(conn.request_path, @mark)] end)
    end

    :ok
  end

  def handle_event([:phoenix, :endpoint, :stop], %{duration: duration}, %{conn: conn}, _config) do
    if TokenPaths.token_path?(conn.request_path) do
      Logger.info(fn -> ["Sent ", status(conn.status), " in ", format_duration(duration)] end)
    end

    :ok
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  defp status(status) when is_integer(status), do: Integer.to_string(status)
  defp status(_status), do: "-"

  @doc false
  # Public for its unit test; formats a native-unit duration as Phoenix does.
  @spec format_duration(integer()) :: String.t()
  def format_duration(duration) do
    microseconds = System.convert_time_unit(duration, :native, :microsecond)

    if microseconds > 1000,
      do: "#{div(microseconds, 1000)}ms",
      else: "#{microseconds}µs"
  end
end
