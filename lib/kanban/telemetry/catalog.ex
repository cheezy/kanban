defmodule Kanban.Telemetry.Catalog do
  @moduledoc """
  The single list of telemetry events the kanban app emits.

  Every entry is plain data, so metrics definitions, documentation and tests
  can all be generated from `events/0`. `Kanban.Telemetry.emit/3` and
  `Kanban.Telemetry.span/3` look events up here and only pass on the metadata
  keys an entry declares.

  ## Entry fields

    * `:name` - the full event name, a list of atoms starting with `:kanban`.
    * `:kind` - `:event` for a single event emitted with `Kanban.Telemetry.emit/3`, or `:span`
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
    * `:legacy` - `true` for an event whose name predates this catalog. Legacy
      names do not all follow the naming rule, and they are never renamed,
      because metrics, dashboards and the stored `metrics_events` history
      depend on them. Every event, legacy or not, is emitted through
      `Kanban.Telemetry`.

  ## Naming rule

  A new event is named `[:kanban, domain, past_tense_action]`:

    * `:kanban` first, always;
    * then the domain, a singular noun such as `:task`, `:board`, `:user` or
      `:api`;
    * then what happened, as a past-tense verb or verb phrase, such as
      `:archived`, `:claimed` or `:metadata_dropped`.

  For example `[:kanban, :task, :archived]`. A span prefix is
  `[:kanban, domain, operation]` and names the operation being timed, or
  `[:kanban, domain]` when the domain is itself the operation, as in
  `[:kanban, :export]`. `:telemetry` adds the `:start`, `:stop` and
  `:exception` suffix.

  ## Metadata rule

  No entry may declare a key that `Kanban.Telemetry.forbidden_key?/1` matches
  (for example `email`, `ip`, `title`, `description`, `body` or `token`).
  `Kanban.Telemetry` drops those keys even if an entry declares them, and a
  test fails if one does.

  ## Runtime-named families

  Two families build their event name from an action atom at runtime. Each
  action has its own entry, generated from the `@api_actions` and
  `@audit_actions` lists in `Kanban.Telemetry.Catalog.Families`:

    * `[:kanban, :api, action]`, emitted by
      `KanbanWeb.API.TaskActions.emit_telemetry/3`. Every entry declares the
      common keys `board_id`, `user_id`, `path` and `method`, which
      `emit_telemetry/3` adds. `Kanban.Metrics.UserActivity` counts the stored
      `kanban.api.task_*` events per `user_id`, so `user_id` must stay.
    * `[:kanban, :audit, action]`, emitted by `Kanban.AuditLog.event/2`. The
      persisted audit row and the `security_audit` log line keep the actor's
      `email` and `ip`, but the telemetry copy never carries them, nor the
      export `filters`, which can contain an email.

  ## Adding an event

  Add a map to the list in this module, with every field above, and emit it
  with `Kanban.Telemetry.emit/3` or `Kanban.Telemetry.span/3`. A new API or
  audit action is a new tuple in `@api_actions` or `@audit_actions` in
  `Kanban.Telemetry.Catalog.Families`. A new task activity event goes in
  `Kanban.Telemetry.Catalog.TaskEvents`, a new account, session or user
  administration event in `Kanban.Telemetry.Catalog.UserEvents`, a
  notification, email delivery or digest event in
  `Kanban.Telemetry.Catalog.NotificationEvents`, a delivery target event in
  `Kanban.Telemetry.Catalog.TargetEvents`, and a broadcast message event in
  `Kanban.Telemetry.Catalog.MessageEvents`. The test
  suite runs in strict mode, so a key the entry does not declare raises there.
  """

  alias Kanban.Telemetry.Catalog.Families
  alias Kanban.Telemetry.Catalog.MessageEvents
  alias Kanban.Telemetry.Catalog.NotificationEvents
  alias Kanban.Telemetry.Catalog.TargetEvents
  alias Kanban.Telemetry.Catalog.TaskEvents
  alias Kanban.Telemetry.Catalog.UserEvents

  @type entry :: %{
          name: [atom(), ...],
          kind: :event | :span,
          domain: atom(),
          measurements: [atom()],
          metadata: [atom()],
          description: String.t(),
          legacy: boolean()
        }

  @core_events [
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
      name: [:kanban, :board, :updated],
      kind: :event,
      domain: :board,
      measurements: [:count],
      metadata: [:board_id, :actor_user_id, :fields],
      description:
        "A board owner changed a board's settings. fields lists the changed field names, never their values.",
      legacy: false
    },
    %{
      name: [:kanban, :board, :deleted],
      kind: :event,
      domain: :board,
      measurements: [:count],
      metadata: [:board_id, :actor_user_id],
      description: "A board owner deleted a board, with its columns, tasks and memberships.",
      legacy: false
    },
    %{
      name: [:kanban, :board, :field_visibility_changed],
      kind: :event,
      domain: :board,
      measurements: [:count],
      metadata: [:board_id, :actor_user_id, :fields],
      description:
        "A board owner changed which task fields the board shows. fields lists the toggled field names.",
      legacy: false
    },
    %{
      name: [:kanban, :board, :member_added],
      kind: :event,
      domain: :board,
      measurements: [:count],
      metadata: [:board_id, :user_id, :access, :actor_user_id],
      description:
        "A user was given access to a board. user_id is the member, actor_user_id the owner who added them.",
      legacy: false
    },
    %{
      name: [:kanban, :board, :member_removed],
      kind: :event,
      domain: :board,
      measurements: [:count],
      metadata: [:board_id, :user_id, :access, :actor_user_id],
      description: "A user was removed from a board. access is the level they held.",
      legacy: false
    },
    %{
      name: [:kanban, :board, :member_access_changed],
      kind: :event,
      domain: :board,
      measurements: [:count],
      metadata: [:board_id, :user_id, :from_access, :to_access, :actor_user_id],
      description: "A board member's access level changed.",
      legacy: false
    },
    %{
      name: [:kanban, :api, :token_bulk_revoked],
      kind: :event,
      domain: :api,
      measurements: [:count],
      metadata: [:board_id, :user_id, :actor_user_id, :reason],
      description:
        "A member's API tokens for a board were revoked because they were removed (reason :member_removed) or set to read_only (:read_only_access). count is the number revoked and may be 0.",
      legacy: false
    },
    %{
      name: [:kanban, :column, :created],
      kind: :event,
      domain: :column,
      measurements: [:count],
      metadata: [:board_id, :column_id, :actor_user_id],
      description: "A board owner added a column.",
      legacy: false
    },
    %{
      name: [:kanban, :column, :updated],
      kind: :event,
      domain: :column,
      measurements: [:count],
      metadata: [:board_id, :column_id, :actor_user_id, :fields],
      description:
        "A board owner changed a column. fields lists the changed field names, never their values.",
      legacy: false
    },
    %{
      name: [:kanban, :column, :deleted],
      kind: :event,
      domain: :column,
      measurements: [:count],
      metadata: [:board_id, :column_id],
      description: "A column was deleted, along with its tasks.",
      legacy: false
    },
    %{
      name: [:kanban, :column, :reordered],
      kind: :event,
      domain: :column,
      measurements: [:count, :column_count],
      metadata: [:board_id],
      description:
        "A board's columns were reordered. column_count is the number of column ids given.",
      legacy: false
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
      description:
        "A user signed in through the browser. Renewing an existing session token does not count.",
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
      measurements: [:count],
      metadata: [:task_id, :identifier, :via, :goal_id],
      description:
        "A task was archived, directly, in bulk (via: :bulk) or with its goal (via: :goal_cascade).",
      legacy: true
    },
    %{
      name: [:kanban, :task, :unarchived],
      kind: :event,
      domain: :task,
      measurements: [:count],
      metadata: [:task_id, :identifier],
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
      measurements: [:count],
      metadata: [:task_id, :completed_by],
      description: "An agent completed a task.",
      legacy: true
    },
    %{
      name: [:kanban, :task, :moved_to_review],
      kind: :event,
      domain: :task,
      measurements: [:count, :time_spent_minutes],
      metadata: [:task_id, :completed_by_id],
      description:
        "A completed task moved to the Review column. time_spent_minutes is an integer, or absent when unknown.",
      legacy: true
    },
    %{
      name: [:kanban, :task, :returned_to_doing],
      kind: :event,
      domain: :task,
      measurements: [:count],
      metadata: [:task_id, :reviewed_by, :review_status],
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
    },
    %{
      name: [:kanban, :metrics, :retention_completed],
      kind: :event,
      domain: :metrics,
      measurements: [:count, :batches],
      metadata: [:retention_days],
      description:
        "The daily metrics retention job finished. count is the number of metrics_events rows removed, batches the number of DELETE batches run.",
      legacy: false
    },
    %{
      name: [:kanban, :export],
      kind: :span,
      domain: :export,
      measurements: [:row_count],
      metadata: [:kind, :format],
      description:
        "Data left Stride as a download. kind is :archive_csv, :metrics_pdf, :workspace_metrics or :audit_log, format the file type; row_count is measured for the archive CSV only.",
      legacy: false
    },
    %{
      name: [:kanban, :rate_limit, :denied],
      kind: :event,
      domain: :rate_limit,
      measurements: [:count],
      metadata: [:surface],
      description:
        "A rate-limit check refused a request. surface names the limited action, never the key, IP address or identity.",
      legacy: false
    },
    %{
      name: [:kanban, :mcp, :request],
      kind: :span,
      domain: :mcp,
      measurements: [],
      metadata: [:method, :outcome],
      description:
        "An MCP JSON-RPC message was handled. method is a fixed label, never the name the client sent, and outcome is set on stop.",
      legacy: false
    },
    %{
      name: [:kanban, :github, :issue_created],
      kind: :event,
      domain: :github,
      measurements: [:count],
      metadata: [:outcome],
      description:
        "An issue report to GitHub finished. outcome is :ok or :error, including when GitHub is not configured.",
      legacy: false
    }
  ]

  @events @core_events ++
            TaskEvents.events() ++
            UserEvents.events() ++
            Families.events() ++
            NotificationEvents.events() ++ TargetEvents.events() ++ MessageEvents.events()

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
