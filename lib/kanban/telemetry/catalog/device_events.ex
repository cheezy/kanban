defmodule Kanban.Telemetry.Catalog.DeviceEvents do
  @moduledoc """
  The mobile app events in `Kanban.Telemetry.Catalog`
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.2, §16).

  `outdated_app_refused` is emitted by `KanbanWeb.Plugs.AppVersion` when it
  answers a request with `426 app_update_required` because the app's
  `X-Stride-App` version is below the configured minimum. Metadata carries
  only the platform, from the fixed set `"ios"` and `"android"`, never the raw
  header, a user, a device or anything else from the request. The refusal
  happens before authentication, so the event is not persisted.

  `signed_in` is emitted by `Kanban.Devices.CodeExchange` once a code
  exchange has created a device and its first tokens, with the platform and
  the device class. `revoked` is emitted by `Kanban.Devices.Revocation` once a
  revocation commits, with the platform and the fixed reason. Neither carries
  the device's name, a token, a user or an id: the `:device_signed_in` and
  `:device_revoked` audit rows hold who and which device. Neither is
  persisted, because the audit log already stores each one.
  `Kanban.Telemetry.Catalog` appends these entries to its own list; nothing
  else should call this module.
  """

  @events [
    %{
      name: [:kanban, :api, :outdated_app_refused],
      kind: :event,
      domain: :api,
      measurements: [:count],
      metadata: [:platform],
      description:
        "A mobile app request was refused with 426 app_update_required because its X-Stride-App version is below the configured minimum for its platform. platform is ios or android, never the raw header.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :device, :signed_in],
      kind: :event,
      domain: :device,
      measurements: [:count],
      metadata: [:platform, :device_class],
      description:
        "A phone or tablet signed in: POST /oauth/token redeemed an authorization code and created the device. platform is ios or android, device_class phone or tablet; never the device's name.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :device, :revoked],
      kind: :event,
      domain: :device,
      measurements: [:count],
      metadata: [:platform, :reason],
      description:
        "A device was revoked and its tokens expired. platform is ios or android; reason is :sign_out, :user, :org_admin, :reuse_detected (an old refresh token, or an authorization code that was already redeemed, was presented again) or :password_changed (the person reset or changed their password). Never the device's name or an id.",
      legacy: false,
      metrics: [counter: :count],
      persist: false,
      tags: [:reason]
    }
  ]

  @doc """
  Returns the mobile app entries, in declaration order.
  """
  @spec events() :: [Kanban.Telemetry.Catalog.entry()]
  def events, do: @events
end
