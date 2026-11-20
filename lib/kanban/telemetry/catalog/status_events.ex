defmodule Kanban.Telemetry.Catalog.StatusEvents do
  @moduledoc """
  The app's status screen events in `Kanban.Telemetry.Catalog`
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §6.16-§6.19).

  `viewed` is emitted by `KanbanWeb.API.Me.TargetController` (W2763) and
  `KanbanWeb.API.Me.GoalController` (W2762) once for each status screen a
  device read: `GET /api/me/targets` with `surface: :targets`, `GET
  /api/me/targets/:id` with `surface: :target`, `GET /api/me/goals` with
  `surface: :goals` and `GET /api/me/goals/:id` with `surface: :goal`, only
  when the read answered 200. `via` is the device's platform, `:ios` or
  `:android`. It never carries a target, a goal, a board, a filter, a user
  or a device. `surface`
  and `via` are its only metadata and its tags.

  It is not persisted: a signed-in device can cause it at will.
  `Kanban.Telemetry.Catalog` appends these entries to its own list; nothing
  else should call this module.
  """

  @events [
    %{
      name: [:kanban, :status, :viewed],
      kind: :event,
      domain: :status,
      measurements: [:count],
      metadata: [:surface, :via],
      description:
        "A device read one of the app's status screens. surface is :targets (the targets list), :target (one target's goal status), :goals (the goals list) or :goal (one goal's task status); via is :ios or :android.",
      legacy: false,
      metrics: [counter: :count],
      persist: false,
      tags: [:surface, :via]
    }
  ]

  @doc """
  Returns the status screen entries, in declaration order.
  """
  @spec events() :: [Kanban.Telemetry.Catalog.entry()]
  def events, do: @events
end
