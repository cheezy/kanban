defmodule Kanban.Telemetry.Catalog.TargetEvents do
  @moduledoc """
  The delivery target events in `Kanban.Telemetry.Catalog`.

  They are emitted by `Kanban.Targets.TargetTelemetry` once the change they
  report has been saved, so a refused, invalid or no-op change emits nothing.
  `status_changed` fires only when the stored status watermark actually
  changes, never on every hourly sweep.

  A delivery target spans boards and has no `board_id` of its own, so only
  the goal assignment events carry one: the goal's board. Metadata carries
  ids, field names and status atoms only. A target's name and description
  are never sent, because telemetry handlers may forward events to tools
  outside the app. `Kanban.Telemetry.Catalog` appends these entries to its
  own list; nothing else should call this module.
  """

  @events [
    %{
      name: [:kanban, :target, :created],
      kind: :event,
      domain: :target,
      measurements: [:count],
      metadata: [:target_id, :actor_user_id],
      description: "A user created a delivery target. actor_user_id is its owner.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :target, :updated],
      kind: :event,
      domain: :target,
      measurements: [:count],
      metadata: [:target_id, :actor_user_id, :fields],
      description:
        "A target's owner changed it. fields lists the changed field names, never their values; saving no change emits nothing.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :target, :archived],
      kind: :event,
      domain: :target,
      measurements: [:count],
      metadata: [:target_id, :actor_user_id],
      description: "A target's owner archived an active, complete target.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :target, :unarchived],
      kind: :event,
      domain: :target,
      measurements: [:count],
      metadata: [:target_id, :actor_user_id],
      description: "A target's owner restored an archived target.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :target, :goal_assigned],
      kind: :event,
      domain: :target,
      measurements: [:count],
      metadata: [:target_id, :goal_id, :board_id, :actor_user_id],
      description:
        "A goal was attached to a target. board_id is the goal's board; assigning the target a goal already has emits nothing.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :target, :goal_unassigned],
      kind: :event,
      domain: :target,
      measurements: [:count],
      metadata: [:target_id, :goal_id, :board_id, :actor_user_id],
      description:
        "A goal was detached from its target. target_id is the target it left; a goal with no target emits nothing.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :target, :status_changed],
      kind: :event,
      domain: :target,
      measurements: [:count],
      metadata: [:target_id, :from_status, :to_status],
      description:
        "The status sweep recorded a new delivery status for a target. from_status is nil on the first observation; both are :on_track, :at_risk, :missed or :complete.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    }
  ]

  @doc """
  Returns the delivery target entries, in declaration order.
  """
  @spec events() :: [Kanban.Telemetry.Catalog.entry()]
  def events, do: @events
end
