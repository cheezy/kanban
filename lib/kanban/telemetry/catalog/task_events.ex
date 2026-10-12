defmodule Kanban.Telemetry.Catalog.TaskEvents do
  @moduledoc """
  The task activity events in `Kanban.Telemetry.Catalog`.

  These events are emitted at the context layer, by
  `Kanban.Tasks.TaskTelemetry`, once the change they report has been saved.
  Because they sit where the change happens, the board UI, the REST API and
  the MCP server each produce exactly one event per change.

  `[:kanban, :api, ...]` events count API requests, while these
  `[:kanban, :task, ...]` events count state changes. A claim made through the
  REST API therefore emits both `[:kanban, :api, :task_claimed]` and
  `[:kanban, :task, :claimed]`, and that is intended.

  Metadata carries ids, enum-like atoms, booleans and changed-field names
  only. Task titles and descriptions, comment bodies, review notes and unclaim
  reasons are never sent. `Kanban.Telemetry.Catalog` appends these entries to
  its own list; nothing else should call this module.
  """

  @events [
    %{
      name: [:kanban, :task, :updated],
      kind: :event,
      domain: :task,
      measurements: [:count],
      metadata: [:task_id, :board_id, :fields, :source, :actor_user_id],
      description:
        "A task was edited in the UI (source :ui) or through the API (:api). fields lists the changed field names, never their values.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :task, :moved],
      kind: :event,
      domain: :task,
      measurements: [:count],
      metadata: [:task_id, :board_id, :from_column_id, :to_column_id],
      description: "A task was moved from one column to another.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :task, :reordered],
      kind: :event,
      domain: :task,
      measurements: [:count, :task_count],
      metadata: [:task_id, :column_id, :board_id],
      description:
        "Tasks were reordered within one column: one task (with task_id) or a whole column (with task_count, the number of task ids given).",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :task, :deleted],
      kind: :event,
      domain: :task,
      measurements: [:count],
      metadata: [:task_id, :board_id],
      description: "A task was deleted.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :task, :claimed],
      kind: :event,
      domain: :task,
      measurements: [:count],
      metadata: [:task_id, :board_id, :user_id],
      description:
        "A task was claimed, through the API or the MCP server. user_id is the claiming user.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :task, :unclaimed],
      kind: :event,
      domain: :task,
      measurements: [:count],
      metadata: [:task_id, :board_id, :user_id, :has_reason],
      description:
        "A claimed task was released back to Ready. has_reason says whether a reason was given; the reason itself is never sent.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :task, :claim_expired],
      kind: :event,
      domain: :task,
      measurements: [:count],
      metadata: [:task_id, :board_id, :user_id],
      description:
        "A claim expired before the task was completed. Emitted once per claim; user_id is the assignee whose claim expired.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :task, :review_approved],
      kind: :event,
      domain: :task,
      measurements: [:count],
      metadata: [:task_id, :board_id, :reviewer_user_id],
      description: "A reviewer approved a task in the review queue.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :task, :review_changes_requested],
      kind: :event,
      domain: :task,
      measurements: [:count],
      metadata: [:task_id, :board_id, :reviewer_user_id],
      description:
        "A reviewer requested changes to a task in the review queue. The review notes are never sent.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :task, :comment_created],
      kind: :event,
      domain: :task,
      measurements: [:count],
      metadata: [:task_id, :board_id, :comment_id, :user_id, :by_agent],
      description:
        "A comment was added to a task. user_id is the author and by_agent says whether an agent wrote it; the comment text is never sent.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    }
  ]

  @doc """
  Returns the task activity entries, in declaration order.
  """
  @spec events() :: [Kanban.Telemetry.Catalog.entry()]
  def events, do: @events
end
