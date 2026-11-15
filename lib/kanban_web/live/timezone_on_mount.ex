defmodule KanbanWeb.TimezoneOnMount do
  @moduledoc """
  Assigns `@timezone` and sets the LiveView process's viewer timezone on every
  mount.

  Once connected, the browser's `timezone` connect param wins. On the static
  render — and when the connect param is missing or invalid — the zone that
  `KanbanWeb.Plugs.Timezone` stored in the session from the `stride_tz` cookie
  is used, so the first byte is already in the viewer's zone. With neither, the
  zone is `"Etc/UTC"`. Every value is validated with
  `KanbanWeb.Timezone.parse_timezone/1`.

  It runs on every live_session in `KanbanWeb.Router`; a live_session without it
  would render in UTC.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, get_connect_params: 1]

  alias KanbanWeb.LocalTime
  alias KanbanWeb.Timezone

  @default "Etc/UTC"

  def on_mount(:default, _params, session, socket) do
    zone = connect_timezone(socket) || session_timezone(session) || @default

    LocalTime.put_timezone(zone)
    {:cont, assign(socket, :timezone, zone)}
  end

  defp connect_timezone(socket) do
    if connected?(socket) do
      socket |> get_connect_params() |> connect_param()
    end
  end

  defp connect_param(%{"timezone" => tz}), do: ok_or_nil(tz)
  defp connect_param(_params), do: nil

  defp session_timezone(%{"timezone" => tz}), do: ok_or_nil(tz)
  defp session_timezone(_session), do: nil

  defp ok_or_nil(tz) do
    case Timezone.parse_timezone(tz) do
      {:ok, zone} -> zone
      :error -> nil
    end
  end
end
