defmodule KanbanWeb.API.Me.NotificationSettingsController do
  @moduledoc """
  The person's push notification settings (W2767,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §6.12, §7.9):

    * `GET /api/me/notification_settings` reads the mode, the eight push
      switches, quiet hours and the time zone;
    * `PUT /api/me/notification_settings` changes any of them.

  It runs behind the `:device_api` pipeline, so `:current_scope` and
  `:current_device` come from `KanbanWeb.Plugs.AuthenticateDeviceToken`,
  which refuses an agent API token. Both routes are plan-gated with
  `:mobile_app` (design §10) through `Kanban.Plans.check_user/3`. Only the
  scope's own settings are read or written; the body names no user, and keys
  other than the ones below are ignored. A change is reported with `via` set
  to the device's platform, and a device revoked while the request was in
  flight changes nothing and gets `401`. Everything else is in `Kanban.Notifications`, and
  every refusal is rendered by `KanbanWeb.API.Me.FallbackController`.
  """
  use KanbanWeb, :controller

  alias Kanban.Notifications
  alias Kanban.Plans

  action_fallback KanbanWeb.API.Me.FallbackController

  # The fields the app may change; anything else in the body is ignored.
  @update_params ~w(mode switches quiet_hours_enabled quiet_start quiet_end time_zone)

  @doc false
  def update_params, do: @update_params

  def show(conn, _params) do
    %{current_scope: scope} = conn.assigns

    with :ok <- Plans.check_user(scope, :mobile_app, surface: :controller) do
      render(conn, :show, settings: Notifications.get_push_settings(scope))
    end
  end

  def update(conn, params) do
    %{current_scope: scope, current_device: device} = conn.assigns
    attrs = Map.take(params, @update_params)
    opts = [via: device.platform, feature: :mobile_app, device: device]

    with :ok <- Plans.check_user(scope, :mobile_app, surface: :controller),
         {:ok, settings} <- Notifications.update_push_settings(scope, attrs, opts) do
      render(conn, :show, settings: settings)
    end
  end
end
