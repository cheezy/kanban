defmodule Kanban.Telemetry.Catalog.PushEvents do
  @moduledoc """
  The push notification events in `Kanban.Telemetry.Catalog`
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.9, §16).

  `settings_changed` is emitted by `Kanban.Notifications.PushSettingsStore`
  once a change to a person's push settings commits, and only when something
  changed. `mode` is `:decisions` or `:every`, the mode after the change;
  `fields` is the sorted names of the settings that changed (`"mode"`,
  `"quiet_hours_enabled"`, `"quiet_start"`, `"quiet_end"`, `"time_zone"` and
  the event type of each push switch, a preset's switches included); `via` is
  `:ios`, `:android` or `:web`. It never carries a value such as a time zone
  or a quiet-hours time, a user or a device. `via` is its only tag.

  It is not persisted: a signed-in device can cause it at will.
  `Kanban.Telemetry.Catalog` appends these entries to its own list; nothing
  else should call this module.
  """

  @events [
    %{
      name: [:kanban, :push, :settings_changed],
      kind: :event,
      domain: :push,
      measurements: [:count],
      metadata: [:mode, :fields, :via],
      description:
        "A person changed their push settings. mode is :decisions or :every after the change; fields names the settings and push switches that changed, never their values; via is :ios, :android or :web.",
      legacy: false,
      metrics: [counter: :count],
      persist: false,
      tags: [:via]
    }
  ]

  @doc """
  Returns the push entries, in declaration order.
  """
  @spec events() :: [Kanban.Telemetry.Catalog.entry()]
  def events, do: @events
end
