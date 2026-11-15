defmodule KanbanWeb.Timezone do
  @moduledoc """
  Captures and validates the viewing user's IANA timezone.

  The browser reports its zone two ways, both wired in `assets/js/app.js` from
  `Intl.DateTimeFormat().resolvedOptions().timeZone`:

    * the `stride_tz` cookie, which `KanbanWeb.Plugs.Timezone` validates and
      stores in the session under `"timezone"`, so the static (pre-WebSocket)
      render already knows the zone;
    * the `timezone` LiveSocket connect param, which wins once the LiveView is
      connected.

  `KanbanWeb.TimezoneOnMount` runs on every live_session and picks between
  them: the connect param when connected, otherwise the session zone, otherwise
  UTC. LiveViews read the result from `@timezone` (and the process from
  `KanbanWeb.LocalTime.timezone/0`). `browser_timezone/1` remains for a caller
  that holds only a socket and no session.

  Both values are user input, so every zone is length-capped and validated
  against the tz database, falling back to UTC on anything unknown rather than
  passing it unchecked into `DateTime.shift_zone/2` later.

  The resulting zone string feeds `Kanban.Timezone.local_today/1` and
  `Kanban.Timezone.local_date/2`.
  """

  import Phoenix.LiveView, only: [connected?: 1, get_connect_params: 1]

  @max_timezone_bytes 64

  @doc """
  The validated viewer timezone for `socket`.

  Returns `"Etc/UTC"` on the static (disconnected) render or when the browser
  supplies an unknown zone.
  """
  @spec browser_timezone(Phoenix.LiveView.Socket.t()) :: String.t()
  def browser_timezone(socket) do
    if connected?(socket) do
      socket |> get_connect_params() |> validate_timezone()
    else
      "Etc/UTC"
    end
  end

  @doc """
  Validates a connect-params map's `"timezone"` against the tz database.

  Returns the zone when valid and `"Etc/UTC"` otherwise — including when the
  param is missing, not a string, or longer than #{@max_timezone_bytes} bytes.
  """
  @spec validate_timezone(map() | nil) :: String.t()
  def validate_timezone(%{"timezone" => tz}) do
    case parse_timezone(tz) do
      {:ok, zone} -> zone
      :error -> "Etc/UTC"
    end
  end

  def validate_timezone(_params), do: "Etc/UTC"

  @doc """
  Parses a single zone string, returning `{:ok, zone}` when it is a string of
  at most #{@max_timezone_bytes} bytes that the tz database knows, and `:error`
  otherwise.

  Unlike `validate_timezone/1` it tells an invalid zone apart from a valid
  `"Etc/UTC"`, so a caller can fall back to another source.
  """
  @spec parse_timezone(term()) :: {:ok, String.t()} | :error
  def parse_timezone(tz) when is_binary(tz) and byte_size(tz) <= @max_timezone_bytes do
    case DateTime.now(tz) do
      {:ok, _now} -> {:ok, tz}
      _error -> :error
    end
  end

  def parse_timezone(_tz), do: :error
end
