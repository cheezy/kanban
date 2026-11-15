defmodule KanbanWeb.Plugs.Timezone do
  @moduledoc """
  Sets the viewer's timezone for the request from the `stride_tz` cookie.

  `assets/js/app.js` writes the browser's IANA zone into `stride_tz` on every
  page load. The cookie is client-controlled, so its value is length-capped and
  validated with `KanbanWeb.Timezone.parse_timezone/1`; a valid zone is stored
  in the session under `"timezone"`, where `KanbanWeb.TimezoneOnMount` finds it
  on the static render. An invalid or missing cookie keeps the zone already in
  the session, or `"Etc/UTC"`.

  The zone is also put on the request process with
  `KanbanWeb.LocalTime.put_timezone/1`, always — including the UTC default — so
  a process reused for a keep-alive connection never carries the previous
  request's zone.
  """
  import Plug.Conn

  alias KanbanWeb.LocalTime
  alias KanbanWeb.Timezone

  @cookie "stride_tz"
  @default "Etc/UTC"
  # A percent-encoded zone is at most three bytes per character of the
  # 64-byte cap that parse_timezone/1 applies to the decoded value.
  @max_cookie_bytes 192

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = fetch_cookies(conn)
    cookie_zone = conn.cookies |> Map.get(@cookie) |> cookie_timezone()
    zone = cookie_zone || session_timezone(conn) || @default

    LocalTime.put_timezone(zone)
    store_timezone(conn, cookie_zone)
  end

  defp cookie_timezone(value) when is_binary(value) and byte_size(value) <= @max_cookie_bytes do
    value |> URI.decode() |> ok_or_nil()
  end

  defp cookie_timezone(_value), do: nil

  defp session_timezone(conn), do: conn |> get_session(:timezone) |> ok_or_nil()

  defp ok_or_nil(tz) do
    case Timezone.parse_timezone(tz) do
      {:ok, zone} -> zone
      :error -> nil
    end
  end

  defp store_timezone(conn, nil), do: conn

  defp store_timezone(conn, zone) do
    if get_session(conn, :timezone) == zone do
      conn
    else
      put_session(conn, :timezone, zone)
    end
  end
end
