defmodule KanbanWeb.Plugs.AppVersion do
  @moduledoc """
  Refuses a mobile app below the minimum version
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.2).

  Reads the `X-Stride-App` header (`ios/1.0.0 (42)`) and asks
  `Kanban.Devices.AppPolicy.check/1`. Below the platform's minimum it answers

      426 {"error": "app_update_required", "store_url": "<store link>"}

  and emits `[:kanban, :api, :outdated_app_refused]` with only the platform.
  Every other request goes on, including one with no header, an unparseable
  header or an unknown platform: `Kanban.Devices.AppPolicy` explains why.

  It runs before authentication, so an outdated app with an expired token is
  sent to the update screen rather than into a refresh loop. The check reads
  only the header and the config, never the database.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Kanban.Devices.AppPolicy

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn |> get_req_header("x-stride-app") |> AppPolicy.check() do
      :ok -> conn
      {:outdated, platform, store_url} -> refuse(conn, platform, store_url)
    end
  end

  defp refuse(conn, platform, store_url) do
    Kanban.Telemetry.emit(
      [:kanban, :api, :outdated_app_refused],
      %{count: 1},
      %{platform: platform_name(platform)}
    )

    conn
    |> put_status(:upgrade_required)
    |> json(%{error: "app_update_required", store_url: store_url})
    |> halt()
  end

  defp platform_name(:ios), do: "ios"
  defp platform_name(:android), do: "android"
end
