defmodule Kanban.Telemetry.Catalog do
  @moduledoc """
  The single list of telemetry events the kanban app emits.

  Every entry is plain data, so metrics definitions, documentation and tests
  can all be generated from `events/0`. `Kanban.Telemetry.emit/3` and
  `Kanban.Telemetry.span/3` look events up here and only pass on the metadata
  keys an entry declares.

  ## Entry fields

    * `:name` - the full event name, a list of atoms starting with `:kanban`.
    * `:kind` - `:event` for a single `:telemetry.execute/3` event, or `:span`
      for a `Kanban.Telemetry.span/3` prefix. `:telemetry` appends `:start`,
      `:stop` and `:exception` to a span prefix. A span's `:measurements` lists
      only the extra stop measurements; `duration`, `monotonic_time` and
      `system_time` are implied.
    * `:domain` - the area of the app the event belongs to. It is always the
      second segment of `:name`.
    * `:measurements` - the measurement keys the event carries.
    * `:metadata` - the metadata keys the event is allowed to carry. Any other
      key is dropped (or raises in strict mode).
    * `:description` - one sentence saying what happened.
    * `:legacy` - `true` for an event that predates this catalog and is still
      emitted with a direct `:telemetry.execute/3` call. Legacy entries record
      what those call sites emit today. Their names do not all follow the
      naming rule, and they are not renamed here, because metrics and
      dashboards depend on them.

  ## Naming rule

  A new event is named `[:kanban, domain, past_tense_action]`:

    * `:kanban` first, always;
    * then the domain, a singular noun such as `:task`, `:board`, `:user` or
      `:api`;
    * then what happened, as a past-tense verb or verb phrase, such as
      `:archived`, `:claimed` or `:metadata_dropped`.

  For example `[:kanban, :task, :archived]`. A span prefix is
  `[:kanban, domain, operation]` and names the operation being timed, because
  `:telemetry` adds the `:start`, `:stop` and `:exception` suffix.

  ## Metadata rule

  No entry may declare a key that `Kanban.Telemetry.forbidden_key?/1` matches
  (for example `email`, `ip`, `title`, `description`, `body` or `token`).
  `Kanban.Telemetry` drops those keys even if an entry declares them, and a
  test fails if one does.

  ## Not yet catalogued

  Two families of events are emitted with names built at runtime and are not
  listed here yet:

    * `[:kanban, :audit, action]`, emitted by `Kanban.AuditLog.event/2`. Its
      metadata can carry `email` and `ip`, which are forbidden keys here.
    * `[:kanban, :api, action]`, emitted by
      `KanbanWeb.API.TaskActions.emit_telemetry/3` for API actions.

  Moving those emitters onto `Kanban.Telemetry` is follow-up work.

  ## Adding an event

  Add a map to the list in this module, with every field above, and emit it
  with `Kanban.Telemetry.emit/3` or `Kanban.Telemetry.span/3`. The test suite
  runs in strict mode, so a key the entry does not declare raises there.
  """

  @type entry :: %{
          name: [atom(), ...],
          kind: :event | :span,
          domain: atom(),
          measurements: [atom()],
          metadata: [atom()],
          description: String.t(),
          legacy: boolean()
        }

  @events [
    %{
      name: [:kanban, :telemetry, :metadata_dropped],
      kind: :event,
      domain: :telemetry,
      measurements: [:count],
      metadata: [:event_name, :reason, :keys],
      description:
        "Kanban.Telemetry dropped metadata keys from an event, because they were forbidden or undeclared. Carries key names only, never values.",
      legacy: false
    },
    %{
      name: [:kanban, :board, :creation],
      kind: :event,
      domain: :board,
      measurements: [:count],
      metadata: [:board_id, :user_id],
      description: "A board was created.",
      legacy: true
    },
    %{
      name: [:kanban, :user, :registration],
      kind: :event,
      domain: :user,
      measurements: [:count],
      metadata: [:user_id],
      description: "A user registered.",
      legacy: true
    },
    %{
      name: [:kanban, :user, :login],
      kind: :event,
      domain: :user,
      measurements: [:count],
      metadata: [:user_id],
      description: "A user logged in through the browser.",
      legacy: true
    },
    %{
      name: [:kanban, :api, :token_created],
      kind: :event,
      domain: :api,
      measurements: [:count],
      metadata: [:user_id, :board_id, :token_id],
      description: "An API token was created.",
      legacy: true
    },
    %{
      name: [:kanban, :api, :token_revoked],
      kind: :event,
      domain: :api,
      measurements: [:count],
      metadata: [:user_id, :token_id],
      description: "An API token was revoked.",
      legacy: true
    },
    %{
      name: [:kanban, :api, :token_deleted],
      kind: :event,
      domain: :api,
      measurements: [:count],
      metadata: [:user_id, :token_id],
      description: "An API token was deleted.",
      legacy: true
    },
    %{
      name: [:kanban, :api, :token_used],
      kind: :event,
      domain: :api,
      measurements: [:count],
      metadata: [:user_id, :token_id],
      description: "An API token authenticated a request.",
      legacy: true
    },
    %{
      name: [:kanban, :api, :request],
      kind: :event,
      domain: :api,
      measurements: [:count, :duration],
      metadata: [:endpoint, :method, :status],
      description: "An API request finished. Duration is in native time units.",
      legacy: true
    },
    %{
      name: [:kanban, :api, :error],
      kind: :event,
      domain: :api,
      measurements: [:count],
      metadata: [:endpoint, :status, :method],
      description: "An API request finished with a status of 400 or above.",
      legacy: true
    },
    %{
      name: [:kanban, :api, :auth_failed],
      kind: :event,
      domain: :api,
      measurements: [:count],
      metadata: [:reason, :path, :method],
      description: "An API request failed bearer-token authentication.",
      legacy: true
    },
    %{
      name: [:kanban, :api, :after_goal_delivered],
      kind: :event,
      domain: :api,
      measurements: [:count],
      metadata: [:goal_id, :board_id, :project_id],
      description: "An after_goal hook was included in a /complete or /mark_reviewed response.",
      legacy: true
    },
    %{
      name: [:kanban, :task, :creation],
      kind: :event,
      domain: :task,
      measurements: [:count],
      metadata: [:task_id, :column_id],
      description: "A task was created.",
      legacy: true
    },
    %{
      name: [:kanban, :task, :archived],
      kind: :event,
      domain: :task,
      measurements: [:task_id],
      metadata: [:identifier, :via, :goal_id],
      description:
        "A task was archived, directly, in bulk (via: :bulk) or with its goal (via: :goal_cascade).",
      legacy: true
    },
    %{
      name: [:kanban, :task, :unarchived],
      kind: :event,
      domain: :task,
      measurements: [:task_id],
      metadata: [:identifier],
      description: "A task was restored from the archive.",
      legacy: true
    },
    %{
      name: [:kanban, :task, :bulk_archived],
      kind: :event,
      domain: :task,
      measurements: [:count],
      metadata: [:board_id],
      description: "A batch of tasks on a board was archived.",
      legacy: true
    },
    %{
      name: [:kanban, :task, :completed],
      kind: :event,
      domain: :task,
      measurements: [:task_id],
      metadata: [:completed_by],
      description: "An agent completed a task.",
      legacy: true
    },
    %{
      name: [:kanban, :task, :moved_to_review],
      kind: :event,
      domain: :task,
      measurements: [:task_id, :time_spent_minutes],
      metadata: [:completed_by_id],
      description: "A completed task moved to the Review column.",
      legacy: true
    },
    %{
      name: [:kanban, :task, :returned_to_doing],
      kind: :event,
      domain: :task,
      measurements: [:task_id],
      metadata: [:reviewed_by, :review_status],
      description: "A reviewed task was sent back to Doing.",
      legacy: true
    },
    %{
      name: [:kanban, :task, :changed_files_missing],
      kind: :event,
      domain: :task,
      measurements: [:count],
      metadata: [:task_id, :identifier, :board_id],
      description: "A task reached review reporting changed files but with no uploaded diff.",
      legacy: true
    },
    %{
      name: [:kanban, :goal, :created_with_tasks],
      kind: :event,
      domain: :goal,
      measurements: [:goal_count, :task_count],
      metadata: [:goal_id, :column_id],
      description: "A goal was created together with its child tasks.",
      legacy: true
    },
    %{
      name: [:kanban, :pubsub, :broadcast],
      kind: :event,
      domain: :pubsub,
      measurements: [:count],
      metadata: [:event, :task_id, :board_id],
      description: "A task or comment change was broadcast over PubSub.",
      legacy: true
    },
    %{
      name: [:kanban, :review, :structured_used],
      kind: :event,
      domain: :review,
      measurements: [:count],
      metadata: [:task_id, :identifier],
      description: "The review panel rendered from the structured review block.",
      legacy: true
    },
    %{
      name: [:kanban, :review, :fallback_used],
      kind: :event,
      domain: :review,
      measurements: [:count],
      metadata: [:task_id, :identifier],
      description: "The review panel fell back to parsing the legacy review summary.",
      legacy: true
    },
    %{
      name: [:kanban, :review_diff_panel, :opened],
      kind: :event,
      domain: :review_diff_panel,
      measurements: [:system_time, :count],
      metadata: [:task_id],
      description: "A reviewer opened the diff panel for a task in the review queue.",
      legacy: true
    },
    %{
      name: [:kanban, :review_diff_panel, :closed],
      kind: :event,
      domain: :review_diff_panel,
      measurements: [:system_time, :count],
      metadata: [:task_id],
      description: "A reviewer closed the diff panel in the review queue.",
      legacy: true
    }
  ]

  @by_name Map.new(@events, fn entry -> {entry.name, entry} end)

  @doc """
  Returns every catalogued event, in declaration order.
  """
  @spec events() :: [entry()]
  def events, do: @events

  @doc """
  Looks up an entry by its full event name (or span prefix).
  """
  @spec fetch(term()) :: {:ok, entry()} | :error
  def fetch(name), do: Map.fetch(@by_name, name)
end
