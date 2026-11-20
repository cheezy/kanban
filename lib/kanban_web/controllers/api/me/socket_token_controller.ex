defmodule KanbanWeb.API.Me.SocketTokenController do
  @moduledoc """
  `POST /api/me/socket_token` (W2765,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.7): a single-use token,
  valid for 60 seconds, that the app passes as the `token` connect parameter
  of `/api/socket` (`KanbanWeb.UserSocket`).

  It runs behind the `:device_api` pipeline, so only a device access token
  reaches it and `:current_scope` and `:current_device` come from
  `KanbanWeb.Plugs.AuthenticateDeviceToken`. The token is bound to that
  device (`KanbanWeb.SocketToken`). The route is plan-gated with
  `:mobile_app` (design §10).

  The token is never stored, logged or put in telemetry: only the hash of its
  id is stored, when it is used. Every refusal is rendered by
  `KanbanWeb.API.Me.FallbackController`.
  """
  use KanbanWeb, :controller

  alias Kanban.Plans
  alias KanbanWeb.SocketToken

  action_fallback KanbanWeb.API.Me.FallbackController

  def create(conn, _params) do
    %{current_scope: scope, current_device: device} = conn.assigns

    with :ok <- Plans.check_user(scope, :mobile_app, surface: :controller) do
      {token, expires_at} = SocketToken.sign(device)

      conn
      |> put_status(:created)
      |> render(:show, token: token, expires_at: expires_at)
    end
  end
end
