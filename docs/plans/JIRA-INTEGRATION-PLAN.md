# Plan: Jira as a Backend for Stride — Architecture Design

## Context

Organizations using Jira for project management want their AI agents to work through the Stride workflow (claim → implement → complete → review) while tasks remain visible and manageable in Jira. The question: what needs to change in Stride to support Jira as a backend?

Stride's architecture is deeply coupled to PostgreSQL — 12 task submodules make direct `Repo` calls, `AgentQueries.get_next_task/2` uses PostgreSQL-specific fragments (JSONB operators, array containment, subqueries), and atomic claiming uses database-level compare-and-swap. There are no existing adapter patterns (`@behaviour`, `@callback`, `defprotocol`) in the codebase.

## Three Approaches Evaluated

### Approach 1: Full Provider/Adapter Pattern (Replace PostgreSQL with Jira)

Define a `Kanban.TaskProvider` behaviour and rewrite all 12 submodules to call through it. **Rejected** — this requires rewriting ~2,000+ lines of core logic, and the most critical features (agent discovery with capability matching, atomic claiming, key_file conflict detection, circular dependency checking) cannot be expressed via Jira's REST API or JQL. Performance would degrade from local DB queries to multiple API roundtrips per operation.

### Approach 2: Bidirectional Sync (Stride is primary, Jira mirrors) ← **Recommended**

Stride remains the system of record with PostgreSQL intact. A new integration layer synchronizes bidirectionally: task changes in Stride push to Jira; Jira webhooks pull changes back to Stride. Agents always interact with Stride's API — Jira is a synchronized view for human stakeholders.

### Approach 3: One-Way Import/Push (Jira → Stride → status back to Jira)

Import tasks from Jira, enrich with AI context in Stride, push status back. **Simpler but limited** — doesn't satisfy orgs wanting Jira as the living task view. Good as Phase 1 of Approach 2.

## Recommended Architecture: Bidirectional Sync

### Why This Approach

1. **Zero disruption to agent workflow** — the critical path (get_next_task → claim → work → complete → hooks) is untouched. PostgreSQL remains the backend for all agent operations.
2. **Full preservation of Stride's AI features** — the 40+ AI-specific fields, agent discovery algorithm, atomic claiming, key_file conflict detection, and hook system all work exactly as they do today.
3. **Jira users get what they need** — tasks appear in Jira with status, priority, assignee, and description synced. Humans manage in Jira; agents execute in Stride.
4. **Naturally phased delivery** — ship value incrementally from outbound-only to full bidirectional sync.

### What Syncs to Jira (and What Doesn't)

**Synced to Jira (human-relevant fields):**

- title, description, acceptance_criteria, priority, status, type
- assignee (mapped to Jira user), dependencies (as Jira issue links)
- completion_summary, time_spent_minutes (on completion)
- Comments (bidirectional)

**Stays exclusively in Stride's PostgreSQL (AI-specific fields):**

- key_files, verification_steps, testing_strategy, pitfalls
- patterns_to_follow, required_capabilities, technology_requirements
- where_context, database_changes, validation_rules
- out_of_scope, security_considerations, integration_points
- telemetry_event, metrics_to_track, logging_requirements
- error_user_message, error_on_failure
- Hook results (before_doing_result, after_doing_result, etc.)

This avoids custom field sprawl in Jira (40+ custom fields would be unusable) while preserving Stride's rich AI context.

### New Module Structure

```text
lib/kanban/integrations/
  jira.ex                    -- Public API facade
  jira/
    client.ex                -- Req-based Jira REST API client (follows GitHub pattern)
    field_mapping.ex         -- Stride fields <-> Jira fields/custom fields
    sync.ex                  -- GenServer subscribing to PubSub for outbound sync
    webhook_handler.ex       -- Processes inbound Jira webhook events
    reconciliation.ex        -- Periodic full-sync for missed webhooks
    config.ex                -- Per-board Jira configuration

lib/kanban/integrations/
  jira_sync_mapping.ex       -- Ecto schema: {stride_task_id, jira_issue_key, synced_at, sync_status}

lib/kanban_web/controllers/api/
  jira_webhook_controller.ex -- POST /api/webhooks/jira endpoint

priv/repo/migrations/
  *_create_jira_sync_mappings.exs
  *_add_jira_config_to_boards.exs
```

### Key Design Decisions

**Identity mapping:** `jira_sync_mappings` table maps Stride task IDs to Jira issue keys (PROJ-123). Both identifier systems coexist. Agents never see Jira keys. Jira issues link back to Stride via a custom field or description footer.

**Column/status mapping:** Configurable per board. Default mapping:

| Stride Column | Jira Status |
| --- | --- |
| Backlog | To Do |
| Ready | To Do (with "ai-ready" label) |
| Doing | In Progress |
| Review | In Review |
| Done | Done |

**Conflict strategy:** Agent operations always win on the Stride side (agents hold atomic claims). Human Jira changes are applied to Stride only when no agent has an active claim on the task. Conflicts are logged and optionally notify the board owner.

**PubSub integration:** The existing `Broadcaster` module (lib/kanban/tasks/broadcaster.ex) already publishes `:task_created`, `:task_updated`, `:task_completed`, `:task_claimed`, `:task_reviewed`, `:task_status_changed` events to `"board:#{board_id}"` topics. A new `Jira.Sync` GenServer subscribes to these events and processes outbound sync asynchronously — fully decoupled from core task logic.

**HTTP client pattern:** Follow the existing `Kanban.GitHub` module (lib/kanban/github.ex) which uses `Req` with an injectable `http_client` via `Application.get_env(:kanban, :http_client, &Req.post/2)` for testability.

### Database Changes

**New table: `jira_sync_mappings`**

```text
id              -- primary key
task_id         -- references tasks(id)
jira_issue_key  -- "PROJ-123"
jira_project_key -- "PROJ"
sync_status     -- :synced | :pending | :error | :conflict
last_synced_at  -- UTC datetime
sync_direction  -- :outbound | :inbound (which side triggered last sync)
error_message   -- nullable, for debugging sync failures
```

**Board schema additions:**

```text
jira_enabled        -- boolean, default false
jira_base_url       -- "https://myorg.atlassian.net"
jira_project_key    -- "PROJ"
jira_api_token      -- encrypted credential
jira_user_email     -- for API auth
jira_column_mapping -- JSONB map: {"Ready" => "To Do", "Doing" => "In Progress", ...}
jira_sync_fields    -- JSONB array of which fields to sync
```

### Plugin/Skills Impact

**None.** The Stride plugin and all skills (claiming, completing, creating) remain unchanged. Agents interact exclusively with Stride's existing `/api/tasks/*` endpoints. The Jira integration is a server-side background concern invisible to agents.

### Hook System Impact

**None.** Hooks are client-side (agent reads `.stride.md` and executes locally). The Jira integration doesn't affect hook execution. Hook results are stored in Stride and NOT synced to Jira (they're agent-internal).

### Phased Implementation

**Phase 1: Outbound Push (Stride → Jira)**

- `Jira.Client` — Req-based API client with auth
- `Jira.Sync` — GenServer subscribing to PubSub, pushing task changes to Jira
- `Jira.FieldMapping` — maps Stride fields to Jira issue fields
- `jira_sync_mappings` migration and schema
- Board schema additions for Jira config
- Board settings UI for configuring Jira connection
- Value: Jira users see agent work in real-time

**Phase 2: Inbound Webhooks (Jira → Stride)**

- `JiraWebhookController` — receives Jira events
- `Jira.WebhookHandler` — processes events, applies changes to Stride tasks
- Webhook signature verification
- Conflict detection (active claim check)
- Value: Human Jira changes flow back to Stride

**Phase 3: Reconciliation & Resilience**

- `Jira.Reconciliation` — periodic full-sync comparing Stride state vs Jira state
- Retry logic for failed syncs
- Admin dashboard showing sync status per board
- Value: Handles missed webhooks and drift

**Phase 4: Board Configuration UI**

- LiveView settings page for Jira integration per board
- Column mapping configuration
- Field sync preferences
- Test connection button
- Sync status indicators on task cards
- Value: Self-service setup without code changes

### Existing Patterns to Follow

| Pattern | Source File | Reuse For |
| --- | --- | --- |
| HTTP client with injectable mock | `lib/kanban/github.ex` | `Jira.Client` |
| PubSub event broadcasting | `lib/kanban/tasks/broadcaster.ex` | `Jira.Sync` subscription |
| Board configuration fields | `lib/kanban/boards/board.ex` (field_visibility) | Jira config JSONB |
| API controller patterns | `lib/kanban_web/controllers/api/task_controller.ex` | Webhook controller |
| Schema with JSONB maps | `lib/kanban/tasks/task.ex` (testing_strategy) | Column mapping |

### What Does NOT Change

- All 12 task submodules (Creation, Lifecycle, AgentWorkflow, AgentQueries, Dependencies, Positioning, Identifiers, Queries, Goals, History, Broadcaster)
- All API endpoints (`/api/tasks/*`)
- Hook system (Hooks, Hooks.Environment, Hooks.Validator)
- Plugin skills (claiming, completing, creating tasks/goals, subagent workflow)
- Agent definitions (task-explorer, task-reviewer)
- Authentication system (API tokens, board access)
- LiveView UI (except adding Jira settings to board config)

## Verification

After implementation, verify:

1. Create a task in Stride on a Jira-enabled board → appears in Jira within seconds
2. Agent claims and completes a task → Jira issue transitions through statuses
3. Human changes priority in Jira → change appears in Stride (Phase 2)
4. Agent claims task while human edits in Jira → agent operation wins, conflict logged
5. Stop Jira webhooks for 10 min, make changes → reconciliation catches up (Phase 3)
6. Full agent workflow (claim → implement → complete) works identically with or without Jira enabled
