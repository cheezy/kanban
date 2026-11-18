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
    }
  ]

  @doc """
  Returns the mobile app entries, in declaration order.
  """
  @spec events() :: [Kanban.Telemetry.Catalog.entry()]
  def events, do: @events
end
