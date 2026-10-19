defmodule Kanban.Telemetry.Catalog.PlanEvents do
  @moduledoc """
  The paid-plan events in `Kanban.Telemetry.Catalog`.

  `feature_refused` is emitted by `Kanban.Plans` when a plan check refuses a
  paid feature. `locked_feature_clicked` is emitted by
  `KanbanWeb.LockedFeatureController` when a signed-in user follows a locked
  feature's Available to organizations prompt. Metadata carries only the
  feature and, for a refusal, the surface that refused it, both from fixed atom
  sets, never a board id, a user id or anything from the request.
  `Kanban.Telemetry.Catalog` appends these entries to its own list; nothing
  else should call this module.
  """

  @events [
    %{
      name: [:kanban, :plan, :feature_refused],
      kind: :event,
      domain: :plan,
      measurements: [:count],
      metadata: [:feature, :surface],
      description:
        "A plan check refused a paid feature because plans are enforced and the board or user is on the free plan. feature is one of Kanban.Plans.features/0 and surface names the entry point, never a board or user.",
      legacy: false,
      metrics: [counter: :count],
      persist: false,
      tags: [:feature, :surface]
    },
    %{
      name: [:kanban, :plan, :locked_feature_clicked],
      kind: :event,
      domain: :plan,
      measurements: [:count],
      metadata: [:feature],
      description:
        "A signed-in user followed a locked feature's Available to organizations prompt. feature is one of Kanban.Plans.features/0; the user is never sent, each user counts at most once per feature a week, and cross-site requests are not counted.",
      legacy: false,
      metrics: [counter: :count],
      persist: true,
      tags: [:feature]
    }
  ]

  @doc """
  Returns the plan entries, in declaration order.
  """
  @spec events() :: [Kanban.Telemetry.Catalog.entry()]
  def events, do: @events
end
