defmodule KanbanWeb.API.Me.DeviceController do
  @moduledoc """
  The person's devices (W2748, docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md
  §7.10, §9.5):

    * `GET /api/me/devices` lists the person's devices that are signed in;
    * `PUT /api/me/devices/current` updates the device the request's token
      belongs to: its push token and push environment, locale, time zone and
      app version;
    * `DELETE /api/me/devices/current` signs this device out;
    * `DELETE /api/me/devices/:id` revokes one of the person's devices.

  It runs behind the `:device_api` pipeline, so `:current_scope` and
  `:current_device` come from `KanbanWeb.Plugs.AuthenticateDeviceToken`.
  These routes are never plan-gated (design §10): a person on a free plan
  must still be able to sign a device out. Another person's device, and an
  id that is not one, answer 404. `DELETE /api/me/devices/:id` is
  idempotent: a device that is already revoked answers 204 and is not
  revoked, audited or announced again. A device revoked while its own
  request was in flight gets 401 from every route, as its token would. Everything else is in `Kanban.Devices`.
  """
  use KanbanWeb, :controller

  alias Kanban.Devices
  alias KanbanWeb.IdParams

  action_fallback KanbanWeb.API.Me.FallbackController

  # The fields the app may change; anything else in the body is ignored.
  @update_params ~w(push_token push_environment locale time_zone app_version)

  def index(conn, _params) do
    %{current_scope: scope, current_device: device} = conn.assigns

    with {:ok, devices} <- Devices.list_devices_for(scope, device) do
      render(conn, :index, devices: devices, current_id: device.id)
    end
  end

  def update_current(conn, params) do
    %{current_scope: scope, current_device: device} = conn.assigns
    attrs = Map.take(params, @update_params)

    with {:ok, updated} <- Devices.update_current(scope, device, attrs, DateTime.utc_now()) do
      render(conn, :show, device: updated, current_id: device.id)
    end
  end

  def delete_current(conn, _params) do
    %{current_scope: scope, current_device: device} = conn.assigns
    revoke(conn, scope, device, :sign_out)
  end

  def delete(conn, %{"id" => id}) do
    %{current_scope: scope} = conn.assigns

    with {:ok, device_id} <- parse_id(id),
         {:ok, device} <- Devices.fetch_device(scope, device_id) do
      revoke(conn, scope, device, :user)
    end
  end

  # The requesting device is re-checked under a lock, so one revoked while
  # this request was in flight revokes nothing and answers 401.
  defp revoke(conn, scope, device, reason) do
    opts = [reason: reason, ip: conn.remote_ip, by_device: conn.assigns.current_device]

    with {:ok, _revoked} <- Devices.revoke_device(scope, device, DateTime.utc_now(), opts) do
      send_resp(conn, :no_content, "")
    end
  end

  defp parse_id(id) do
    case IdParams.parse(id) do
      {:ok, device_id} -> {:ok, device_id}
      :error -> {:error, :not_found}
    end
  end
end
