defmodule Kanban.Telemetry.Catalog.TaskLifecycleEvents do
  @moduledoc """
  The legacy task lifecycle events in `Kanban.Telemetry.Catalog`: a task
  created, archived, unarchived, archived in bulk, completed, moved to Review,
  returned to Doing or sent to review with no uploaded diff, and a goal
  created together with its child tasks.

  Their names predate the catalog and are never renamed, because metrics,
  dashboards and the stored `metrics_events` history depend on them. The
  newer task activity events are in `Kanban.Telemetry.Catalog.TaskEvents`.

  Metadata carries ids, identifiers, counts and enum-like atoms only, never a
  title or a description. `Kanban.Telemetry.Catalog` appends these entries to
  its own list; nothing else should call this module.
  """

  @events [
    %{
      name: [:kanban, :task, :creation],
      kind: :event,
      domain: :task,
      measurements: [:count],
      metadata: [:task_id, :column_id],
      description: "A task was created.",
      legacy: true,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :task, :archived],
      kind: :event,
      domain: :task,
      measurements: [:count],
      metadata: [:task_id, :identifier, :via, :goal_id],
      description:
        "A task was archived, directly, in bulk (via: :bulk) or with its goal (via: :goal_cascade).",
      legacy: true,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :task, :unarchived],
      kind: :event,
      domain: :task,
      measurements: [:count],
      metadata: [:task_id, :identifier],
      description: "A task was restored from the archive.",
      legacy: true,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :task, :bulk_archived],
      kind: :event,
      domain: :task,
      measurements: [:count],
      metadata: [:board_id],
      description:
        "A batch of completed tasks on a board was archived. count is the number of tasks archived and may be 0.",
      legacy: true,
      metrics: [sum: :count],
      persist: false
    },
    %{
      name: [:kanban, :task, :completed],
      kind: :event,
      domain: :task,
      measurements: [:count],
      metadata: [:task_id, :completed_by],
      description: "An agent completed a task.",
      legacy: true,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :task, :moved_to_review],
      kind: :event,
      domain: :task,
      measurements: [:count, :time_spent_minutes],
      metadata: [:task_id, :completed_by_id],
      description:
        "A completed task moved to the Review column. time_spent_minutes is an integer, or absent when unknown.",
      legacy: true,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :task, :returned_to_doing],
      kind: :event,
      domain: :task,
      measurements: [:count],
      metadata: [:task_id, :reviewed_by, :review_status],
      description: "A reviewed task was sent back to Doing.",
      legacy: true,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :task, :changed_files_missing],
      kind: :event,
      domain: :task,
      measurements: [:count],
      metadata: [:task_id, :identifier, :board_id],
      description: "A task reached review reporting changed files but with no uploaded diff.",
      legacy: true,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :goal, :created_with_tasks],
      kind: :event,
      domain: :goal,
      measurements: [:goal_count, :task_count],
      metadata: [:goal_id, :column_id],
      description: "A goal was created together with its child tasks.",
      legacy: true,
      metrics: [counter: :goal_count],
      persist: false
    }
  ]

  @doc """
  Returns the legacy task lifecycle entries, in declaration order.
  """
  @spec events() :: [Kanban.Telemetry.Catalog.entry()]
  def events, do: @events
end
