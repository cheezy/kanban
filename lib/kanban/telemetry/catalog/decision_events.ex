defmodule Kanban.Telemetry.Catalog.DecisionEvents do
  @moduledoc """
  The decisions events in `Kanban.Telemetry.Catalog`
  (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.4, §16): `built`,
  emitted by `Kanban.Decisions` each time it builds the decisions waiting on
  a person, and `acted_on`, emitted when a person first acts on one.

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

  `acted_on` is emitted by `Kanban.Decisions.ActedOn` the first time a
  person acts on a decision, on the web or in the app (§16, §23). It
  measures `count: 1` and `wait_seconds`, the whole seconds from the
  decision's `since` to the action, never below 0. Its metadata is the
  decision's `kind`, the `action` (`:approve`, `:request_changes`, `:move`,
  `:promote` or `:reply`), `via` (`:web`, `:ios` or `:android`), and the
  `task_id` and `board_id`; `task_id` is left out for `:ready_empty`, which
  has no task. Its tags are `kind` and `via`, never an id. Its domain is the
  singular `:decision`, as the naming rule prefers.

  It is persisted: it fires at most once per decision, a `decision_actions`
  row decides which action was first, and only a signed-in person acting on
  a decision an agent caused can cause it.

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
    },
    %{
      name: [:kanban, :decision, :acted_on],
      kind: :event,
      domain: :decision,
      measurements: [:count, :wait_seconds],
      metadata: [:kind, :action, :via, :task_id, :board_id],
      description:
        "A person first acted on a decision, on the web or in the app. wait_seconds is the whole seconds from the decision's since to the action, never below 0; action is :approve, :request_changes, :move, :promote or :reply; via is :web, :ios or :android; task_id is left out for ready_empty.",
      legacy: false,
      metrics: [summary: :wait_seconds, counter: :count],
      persist: true,
      tags: [:kind, :via]
    }
  ]

  @doc """
  Returns the decisions entries, in declaration order.
  """
  @spec events() :: [Kanban.Telemetry.Catalog.entry()]
  def events, do: @events
end
