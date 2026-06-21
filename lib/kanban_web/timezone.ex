defmodule KanbanWeb.Timezone do
  @moduledoc """
  Captures and validates the viewing user's IANA timezone from the LiveSocket
  connect params, for any LiveView that buckets data by the viewer's local day.

  The browser sends its zone via the `timezone` connect param
  (`Intl.DateTimeFormat().resolvedOptions().timeZone`, wired in
  `assets/js/app.js`). `get_connect_params/1` returns `nil` on the static
  (pre-WebSocket) render, so we default to UTC there; the browser value is user
  input, so we validate it against the tz database and fall back to UTC on
  anything unknown rather than passing it unchecked into `DateTime.shift_zone/2`
  later.

  The resulting zone string feeds `Kanban.Timezone.local_today/1` and
  `Kanban.Timezone.local_date/2`.
  """

  import Phoenix.LiveView, only: [connected?: 1, get_connect_params: 1]

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
  param is missing or not a string.
  """
  @spec validate_timezone(map() | nil) :: String.t()
  def validate_timezone(%{"timezone" => tz}) when is_binary(tz) do
    case DateTime.now(tz) do
      {:ok, _now} -> tz
      _error -> "Etc/UTC"
    end
  end

  def validate_timezone(_params), do: "Etc/UTC"
end
