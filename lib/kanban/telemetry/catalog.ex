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
  `[:kanban, domain, operation]` and names the operation being timed, because
  `:telemetry` adds the `:start`, `:stop` and `:exception` suffix.

  ## Metadata rule

  No entry may declare a key that `Kanban.Telemetry.forbidden_key?/1` matches
  (for example `email`, `ip`, `title`, `description`, `body` or `token`).
  `Kanban.Telemetry` drops those keys even if an entry declares them, and a
  test fails if one does.

  ## Runtime-named families

  Two families build their event name from an action atom at runtime. Each
  action has its own entry, generated from the `@api_actions` and
  `@audit_actions` lists in this module:

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
  audit action is a new tuple in `@api_actions` or `@audit_actions`. The test suite
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
    }
  ]

  # Keys `KanbanWeb.API.TaskActions.emit_telemetry/3` adds to every API event.
  # Kanban.Metrics.UserActivity counts stored kanban.api.task_* events by
  # user_id, so user_id must stay declared.
  @api_common_metadata [:board_id, :user_id, :path, :method]

  # {action, extra metadata keys, description} for [:kanban, :api, action].
  @api_actions [
    {:next_task_fetched, [:task_id, :priority], "An agent fetched its next task."},
    {:task_claimed, [:task_id, :priority, :api_token_id, :specific_task],
     "An agent claimed a task."},
    {:task_completed, [:task_id, :time_spent_minutes], "An agent completed a task."},
    {:task_listed, [:count], "An agent listed tasks."},
    {:comments_listed, [:task_id, :count], "An agent listed a task's comments."},
    {:comment_created, [:task_id], "An agent added a comment to a task."},
    {:task_created, [:task_id], "An agent created a task."},
    {:goal_created, [:goal_id, :child_task_count, :batch, :batch_index],
     "An agent created a goal with its child tasks."},
    {:batch_goals_created, [:total_goals], "An agent created goals in one batch."},
    {:task_create_forbidden_fields_filtered, [:goal_fields, :child_fields],
     "Fields an agent may not set were dropped from a create request."},
    {:task_updated, [:task_id], "An agent updated a task."},
    {:task_update_column_change_forbidden, [:task_id],
     "An agent tried to move a task to another column with an update."},
    {:task_update_forbidden_fields_filtered, [:task_id, :fields],
     "Fields an agent may not set were dropped from an update request."},
    {:task_unclaimed, [:task_id], "An agent released a claimed task."},
    {:task_marked_done, [:task_id, :review_status], "A reviewed task was marked done."},
    {:task_returned_to_doing, [:task_id, :review_status],
     "A reviewed task was sent back to Doing."},
    {:after_goal_reported, [:task_id, :exit_code], "An agent reported its after_goal result."},
    {:task_changed_files_persisted, [:task_id, :file_count],
     "An agent's changed files were stored on a task."},
    {:dependencies_fetched, [:task_id], "An agent fetched a task's dependencies."},
    {:dependents_fetched, [:task_id, :count], "An agent fetched a task's dependents."},
    {:task_tree_fetched, [:task_id], "An agent fetched a task tree."},
    {:after_goal_status_fetched, [:task_id], "An agent fetched a goal's after_goal status."},
    {:mcp_tool_called, [:tool, :is_error], "An agent called an MCP tool."}
  ]

  # {action, metadata keys, description} for [:kanban, :audit, action]. The
  # telemetry copy never carries email, ip or filters; see Kanban.AuditLog.
  @audit_actions [
    {:login_failed, [], "A browser sign-in failed."},
    {:password_reset_requested, [], "A password reset was requested."},
    {:api_token_auth_failed, [:reason], "An API request presented a bad bearer token."},
    {:api_token_created, [:user_id, :board_id, :token_id], "An API token was created."},
    {:api_token_revoked, [:user_id, :token_id], "An API token was revoked."},
    {:comment_deleted_by_owner, [:user_id, :board_id, :task_id, :comment_id, :author_user_id],
     "A board owner deleted someone else's comment."},
    {:completion_notes_credential_suspected, [:task_id, :agent_name],
     "Completion notes looked like they contained a credential."},
    {:two_factor_enabled, [:user_id], "A user turned on two-factor authentication."},
    {:two_factor_disabled, [:user_id, :method], "A user turned off two-factor authentication."},
    {:recovery_codes_regenerated, [:user_id], "A user regenerated their recovery codes."},
    {:two_factor_recovery_code_used, [:user_id], "A user signed in with a recovery code."},
    {:login_succeeded_two_factor, [:user_id, :method], "A user completed a two-factor sign-in."},
    {:two_factor_challenge_failed, [:user_id, :method], "A two-factor challenge failed."},
    {:permission_denied, [:user_id, :gate], "A user was refused access by a permission gate."},
    {:sudo_mode_entered, [:user_id], "A recently authenticated user passed a sudo-mode check."},
    {:audit_log_exported, [:user_id, :format], "An admin exported the audit log."}
  ]

  @api_events (for {action, keys, description} <- @api_actions do
                 %{
                   name: [:kanban, :api, action],
                   kind: :event,
                   domain: :api,
                   measurements: [:count],
                   metadata: keys ++ @api_common_metadata,
                   description: description,
                   legacy: true
                 }
               end)

  @audit_events (for {action, keys, description} <- @audit_actions do
                   %{
                     name: [:kanban, :audit, action],
                     kind: :event,
                     domain: :audit,
                     measurements: [:count],
                     metadata: keys,
                     description: description,
                     legacy: true
                   }
                 end)

  @events @core_events ++ @api_events ++ @audit_events

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
