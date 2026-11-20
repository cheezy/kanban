defmodule Kanban.Telemetry.Catalog.ReviewPanelEvents do
  @moduledoc """
  The web review screen events in `Kanban.Telemetry.Catalog`: which review
  report a task's review showed (`structured_used` for one built from the
  structured review block, `fallback_used` for one parsed from the legacy
  review summary), and the review queue's diff panel being opened and
  closed.

  Their names predate the catalog and are never renamed. The app approval
  events are in `Kanban.Telemetry.Catalog.ReviewEvents`. Metadata carries the
  task id and identifier only, never review notes. `Kanban.Telemetry.Catalog`
  appends these entries to its own list; nothing else should call this
  module.
  """

  @events [
    %{
      name: [:kanban, :review, :structured_used],
      kind: :event,
      domain: :review,
      measurements: [:count],
      metadata: [:task_id, :identifier],
      description: "A task's review report, built from the structured review block, was shown.",
      legacy: true,
      metrics: [counter: :count],
      persist: true
    },
    %{
      name: [:kanban, :review, :fallback_used],
      kind: :event,
      domain: :review,
      measurements: [:count],
      metadata: [:task_id, :identifier],
      description: "A task's review report, parsed from the legacy review summary, was shown.",
      legacy: true,
      metrics: [counter: :count],
      persist: true
    },
    %{
      name: [:kanban, :review_diff_panel, :opened],
      kind: :event,
      domain: :review_diff_panel,
      measurements: [:system_time, :count],
      metadata: [:task_id],
      description: "A reviewer opened the diff panel for a task in the review queue.",
      legacy: true,
      metrics: [counter: :count],
      persist: true
    },
    %{
      name: [:kanban, :review_diff_panel, :closed],
      kind: :event,
      domain: :review_diff_panel,
      measurements: [:system_time, :count],
      metadata: [:task_id],
      description: "A reviewer closed the diff panel in the review queue.",
      legacy: true,
      metrics: [counter: :count],
      persist: true
    }
  ]

  @doc """
  Returns the web review screen entries, in declaration order.
  """
  @spec events() :: [Kanban.Telemetry.Catalog.entry()]
  def events, do: @events
end
