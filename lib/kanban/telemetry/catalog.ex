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
    * `:metrics` - the metrics `KanbanWeb.Telemetry.CatalogMetrics` builds
      for the event, as a keyword list of `{type, measurement}`. The type is
      `:counter`, `:sum` or `:summary`. Most events take
      `[counter: :count]`; a span takes `[summary: :duration]`, a duration
      summary of its `:stop` event.
    * `:persist` - whether `KanbanWeb.Telemetry.MetricsStorage` stores the
      entry's first metric in `metrics_events`. Store only events that are
      rare enough not to flood the table and that cannot be triggered at will
      by unauthenticated traffic.
    * `:tags` - optional. The metadata keys the metrics are broken down by.
      Only low-cardinality labels such as `:endpoint` or `:outcome`; never an
      id.

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
  `Kanban.Telemetry.Catalog.Families`. Board, membership and column, task
  activity, account and user administration, notification, delivery target,
  broadcast message, and goal, dependency or after_goal events go in
  `BoardEvents`, `TaskEvents`, `UserEvents`, `NotificationEvents`,
  `TargetEvents`, `MessageEvents` and `GoalEvents` under
  `Kanban.Telemetry.Catalog`. The test suite runs in strict mode, so a key the
  entry does not declare raises there, and it fails if an entry's metrics,
  persist flag or tags are invalid.
  """

  alias Kanban.Telemetry.Catalog.BoardEvents
  alias Kanban.Telemetry.Catalog.Families
  alias Kanban.Telemetry.Catalog.GoalEvents
  alias Kanban.Telemetry.Catalog.MessageEvents
  alias Kanban.Telemetry.Catalog.NotificationEvents
  alias Kanban.Telemetry.Catalog.TargetEvents
  alias Kanban.Telemetry.Catalog.TaskEvents
  alias Kanban.Telemetry.Catalog.UserEvents

  @type entry :: %{
          required(:name) => [atom(), ...],
          required(:kind) => :event | :span,
          required(:domain) => atom(),
          required(:measurements) => [atom()],
          required(:metadata) => [atom()],
          required(:description) => String.t(),
          required(:legacy) => boolean(),
          required(:metrics) => [{:counter | :sum | :summary, atom()}, ...],
          required(:persist) => boolean(),
          optional(:tags) => [atom()]
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
      legacy: false,
      metrics: [sum: :count],
      persist: false
    },
    %{
      name: [:kanban, :user, :registration],
      kind: :event,
      domain: :user,
      measurements: [:count],
      metadata: [:user_id],
      description: "A user registered.",
      legacy: true,
      metrics: [sum: :count],
      persist: true
    },
    %{
      name: [:kanban, :user, :login],
      kind: :event,
      domain: :user,
      measurements: [:count],
      metadata: [:user_id],
      description:
        "A user signed in through the browser. Renewing an existing session token does not count.",
      legacy: true,
      metrics: [counter: :count],
      persist: true
    },
    %{
      name: [:kanban, :api, :token_created],
      kind: :event,
      domain: :api,
      measurements: [:count],
      metadata: [:user_id, :board_id, :token_id],
      description: "An API token was created.",
      legacy: true,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :api, :token_revoked],
      kind: :event,
      domain: :api,
      measurements: [:count],
      metadata: [:user_id, :token_id],
      description: "An API token was revoked.",
      legacy: true,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :api, :token_deleted],
      kind: :event,
      domain: :api,
      measurements: [:count],
      metadata: [:user_id, :token_id],
      description: "An API token was deleted.",
      legacy: true,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :api, :token_used],
      kind: :event,
      domain: :api,
      measurements: [:count],
      metadata: [:user_id, :token_id],
      description: "An API token authenticated a request.",
      legacy: true,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :api, :request],
      kind: :event,
      domain: :api,
      measurements: [:count, :duration],
      metadata: [:endpoint, :method, :status],
      description: "An API request finished. Duration is in native time units.",
      legacy: true,
      metrics: [counter: :count, summary: :duration],
      persist: true,
      tags: [:endpoint, :method]
    },
    %{
      name: [:kanban, :api, :error],
      kind: :event,
      domain: :api,
      measurements: [:count],
      metadata: [:endpoint, :status, :method],
      description: "An API request finished with a status of 400 or above.",
      legacy: true,
      metrics: [counter: :count],
      persist: true,
      tags: [:endpoint, :status]
    },
    %{
      name: [:kanban, :api, :auth_failed],
      kind: :event,
      domain: :api,
      measurements: [:count],
      metadata: [:reason, :path, :method],
      description: "An API request failed bearer-token authentication.",
      legacy: true,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :api, :after_goal_delivered],
      kind: :event,
      domain: :api,
      measurements: [:count],
      metadata: [:goal_id, :board_id, :project_id],
      description: "An after_goal hook was included in a /complete or /mark_reviewed response.",
      legacy: true,
      metrics: [counter: :count],
      persist: true
    },
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
      description: "A batch of tasks on a board was archived.",
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
    },
    %{
      name: [:kanban, :pubsub, :broadcast],
      kind: :event,
      domain: :pubsub,
      measurements: [:count],
      metadata: [:event, :task_id, :board_id],
      description: "A task or comment change was broadcast over PubSub.",
      legacy: true,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :review, :structured_used],
      kind: :event,
      domain: :review,
      measurements: [:count],
      metadata: [:task_id, :identifier],
      description: "The review panel rendered from the structured review block.",
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
      description: "The review panel fell back to parsing the legacy review summary.",
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
    },
    %{
      name: [:kanban, :metrics, :retention_completed],
      kind: :event,
      domain: :metrics,
      measurements: [:count, :batches],
      metadata: [:retention_days],
      description:
        "The daily metrics retention job finished. count is the number of metrics_events rows removed, batches the number of DELETE batches run.",
      legacy: false,
      metrics: [sum: :count],
      persist: true
    },
    %{
      name: [:kanban, :export],
      kind: :span,
      domain: :export,
      measurements: [:row_count],
      metadata: [:kind, :format],
      description:
        "Data left Stride as a download. kind is :archive_csv, :metrics_pdf, :workspace_metrics or :audit_log, format the file type; row_count is measured for the archive CSV only.",
      legacy: false,
      metrics: [summary: :duration],
      persist: true,
      tags: [:kind, :format]
    },
    %{
      name: [:kanban, :rate_limit, :denied],
      kind: :event,
      domain: :rate_limit,
      measurements: [:count],
      metadata: [:surface],
      description:
        "A rate-limit check refused a request. surface names the limited action, never the key, IP address or identity.",
      legacy: false,
      metrics: [counter: :count],
      persist: false,
      tags: [:surface]
    },
    %{
      name: [:kanban, :mcp, :request],
      kind: :span,
      domain: :mcp,
      measurements: [],
      metadata: [:method, :outcome],
      description:
        "An MCP JSON-RPC message was handled. method is a fixed label, never the name the client sent, and outcome is set on stop.",
      legacy: false,
      metrics: [summary: :duration],
      persist: false,
      tags: [:method, :outcome]
    },
    %{
      name: [:kanban, :github, :issue_created],
      kind: :event,
      domain: :github,
      measurements: [:count],
      metadata: [:outcome],
      description:
        "An issue report to GitHub finished. outcome is :ok or :error, including when GitHub is not configured.",
      legacy: false,
      metrics: [counter: :count],
      persist: true,
      tags: [:outcome]
    }
  ]

  @events @core_events ++
            BoardEvents.events() ++
            TaskEvents.events() ++
            UserEvents.events() ++
            Families.events() ++
            NotificationEvents.events() ++
            TargetEvents.events() ++ MessageEvents.events() ++ GoalEvents.events()

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
