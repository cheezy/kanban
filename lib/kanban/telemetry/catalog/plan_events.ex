defmodule Kanban.Telemetry.Catalog.PlanEvents do
  @moduledoc """
  The paid-plan events in `Kanban.Telemetry.Catalog`.

  They are emitted by `Kanban.Plans` when a plan check refuses a paid feature.
  Metadata carries only the feature and the surface that refused it, both from
  fixed atom sets, never a board id, a user id or anything from the request.
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
    }
  ]

  @doc """
  Returns the plan entries, in declaration order.
  """
  @spec events() :: [Kanban.Telemetry.Catalog.entry()]
  def events, do: @events
end
