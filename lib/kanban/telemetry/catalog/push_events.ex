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

  `sent`, `failed` and `held` are emitted by `Kanban.Push.PushWorker`
  (W2771): `sent` once per device a push service accepted, `failed` once per
  device it did not, and `held` once per job held at send time (`:mode`,
  `:quiet_hours` or `:resolved`). They carry the `platform` (`:ios` or
  `:android`, not on `held`), the notification's `event_type` and, on
  `failed` and `held`, a bounded `reason`, which is their only tag. They
  never carry a push token, a title, a body, a target name, a user or a
  device. `Kanban.Push.SummaryWorker` (W2772) emits `sent` and `failed` for
  its summary push too, with `event_type: :quiet_hours_summary`.

  `summary` is emitted by `Kanban.Push.SummaryWorker` once for each quiet
  period whose summary it took, with its `outcome`: `:sent`, `:failed`,
  `:nothing_waiting`, `:no_device`, `:switched_off`, `:plan_locked` or
  `:user_inactive`. `outcome` is its only metadata and its tag.

  None is persisted: a signed-in device can cause `settings_changed` at
  will, and the delivery events are counted live.
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
    },
    %{
      name: [:kanban, :push, :sent],
      kind: :event,
      domain: :push,
      measurements: [:count],
      metadata: [:platform, :event_type],
      description:
        "A push service accepted one notification push for one device. platform is :ios or :android; event_type is the notification's event type, or :quiet_hours_summary for the summary sent when quiet hours end.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :push, :failed],
      kind: :event,
      domain: :push,
      measurements: [:count],
      metadata: [:platform, :event_type, :reason],
      description:
        "A notification push, or the summary sent when quiet hours end (event_type :quiet_hours_summary), to one device was not accepted. reason is a bounded atom such as :unregistered (the token was cleared), :rate_limited, :unavailable, :not_configured or :rejected.",
      legacy: false,
      metrics: [counter: :count],
      persist: false,
      tags: [:reason]
    },
    %{
      name: [:kanban, :push, :held],
      kind: :event,
      domain: :push,
      measurements: [:count],
      metadata: [:event_type, :reason],
      description:
        "A notification push was held at send time and not sent. reason is :mode (the push switch was turned off), :quiet_hours (the recipient's quiet hours held it) or :resolved (the decision was no longer open).",
      legacy: false,
      metrics: [counter: :count],
      persist: false,
      tags: [:reason]
    },
    %{
      name: [:kanban, :push, :summarized],
      kind: :event,
      domain: :push,
      measurements: [:count],
      metadata: [:outcome],
      description:
        "The summary push for one ended quiet period was taken. outcome is :sent, :failed, :nothing_waiting, :no_device, :switched_off, :plan_locked or :user_inactive.",
      legacy: false,
      metrics: [counter: :count],
      persist: false,
      tags: [:outcome]
    }
  ]

  @doc """
  Returns the push entries, in declaration order.
  """
  @spec events() :: [Kanban.Telemetry.Catalog.entry()]
  def events, do: @events
end
