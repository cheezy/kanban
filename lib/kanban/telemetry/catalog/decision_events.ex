defmodule Kanban.Telemetry.Catalog.DecisionEvents do
  @moduledoc """
  The decisions events in `Kanban.Telemetry.Catalog`
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.4, §16), emitted by
  `Kanban.Decisions` each time it builds the decisions waiting on a person.

  `built` measures `count`, the items waiting before the 100-item cap, and
  `duration`, in native time units. Its only metadata is `source`, the fixed
  atom naming who asked: `:api` for `GET /api/me/decisions` and
  `GET /api/me/reviews`, `:channel` for the inbox channel, `:push` for the push worker's
  open-decision check and badge (`Kanban.Push.PushWorker`). It never carries
  a user, a board, a task or an item.

  The domain is `:decisions`, plural, as the design names the event, rather
  than the singular noun the catalog's naming rule prefers: it is the name of
  the `Kanban.Decisions` context.

  It is not persisted: a signed-in device can cause it at will.
  `Kanban.Telemetry.Catalog` appends these entries to its own list; nothing
  else should call this module.
  """

  @events [
    %{
      name: [:kanban, :decisions, :built],
      kind: :event,
      domain: :decisions,
      measurements: [:count, :duration],
      metadata: [:source],
      description:
        "Kanban.Decisions built a person's decisions. count is the items waiting before the 100-item cap; duration is in native time units; source is :api, :channel or :push.",
      legacy: false,
      metrics: [sum: :count, summary: :duration],
      persist: false,
      tags: [:source]
    }
  ]

  @doc """
  Returns the decisions entries, in declaration order.
  """
  @spec events() :: [Kanban.Telemetry.Catalog.entry()]
  def events, do: @events
end
