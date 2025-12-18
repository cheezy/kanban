# Task Claiming Timeout Implementation Summary

**Date:** 2025-12-18
**Improvement:** #1 from IMPROVEMENTS.md
**Timeout Duration:** 60 minutes

## Overview

Implemented automatic task claim expiration to prevent abandoned tasks from blocking other agents when an agent crashes or disconnects. Tasks claimed by an agent will automatically be released back to "open" status after 60 minutes of inactivity.

## Changes Made

### 1. Updated Task 08: Add Task Ready/Claim Endpoints

**File:** `08-add-task-ready-endpoint.md`

**Key Changes:**
- **Complexity**: Updated from "3-4 files" to "4-5 files" to account for background job
- **Description**: Added timeout/auto-release requirement
- **Database Schema**: Added `claimed_at` and `claim_expires_at` fields
- **Query Logic**: Updated to check for expired claims when finding next task
- **Claim Logic**: Updated to set `claimed_at` and `claim_expires_at` (60 minutes from now)
- **Background Job**: Added `release_expired_claims()` function and Oban worker
- **Verification**: Added expiry testing scenarios
- **Observability**: Added telemetry events and metrics for claim expiration
- **Out of Scope**: Moved timeout from "future enhancement" to implemented feature

**New Features:**
1. **Expired Claim Detection**: Tasks with `claim_expires_at < NOW()` are treated as "open"
2. **Atomic Claiming with Expiry**: Sets both timestamps atomically when claiming
3. **Background Job**: Oban worker runs every 5 minutes to clean up expired claims
4. **PubSub Broadcasts**: Notifies all clients when claims expire
5. **Telemetry Events**: `[:kanban, :task, :claim_expired]` for monitoring

### 2. Updated Task 02: Add Task Metadata Fields

**File:** `02-add-task-metadata-fields.md`

**Key Changes:**
- **Fields Added**:
  - `claimed_at` (utc_datetime) - When task was claimed by an agent
  - `claim_expires_at` (utc_datetime) - When claim expires (60 minutes from claimed_at)
- **Migration**: Added timestamp columns and indexes
- **Schema**: Added fields to Task schema and changeset

**Indexes Added:**
```elixir
create index(:tasks, [:claim_expires_at])
create index(:tasks, [:status, :claim_expires_at])
```

These indexes optimize the background job's query performance.

### 3. Updated IMPROVEMENTS.md

**File:** `IMPROVEMENTS.md`

**Key Changes:**
- Marked improvement #1 as "IMPLEMENTED"
- Added status section with implementation details
- Reformatted all improvements with proper markdown headers (##)
- Added reference to task 08 for full implementation details

## Technical Implementation

### Database Changes

**New Fields:**
```sql
ALTER TABLE tasks ADD COLUMN claimed_at TIMESTAMP;
ALTER TABLE tasks ADD COLUMN claim_expires_at TIMESTAMP;

CREATE INDEX idx_tasks_claim_expires_at ON tasks(claim_expires_at);
CREATE INDEX idx_tasks_status_claim_expires ON tasks(status, claim_expires_at);
```

### Query Logic

**Finding Next Available Task:**
```elixir
where: t.status == "open" or (t.status == "in_progress" and t.claim_expires_at < ^now)
```

**Atomic Claiming:**
```elixir
set: [
  status: "in_progress",
  claimed_at: now,
  claim_expires_at: DateTime.add(now, 60, :minute),
  updated_at: now
]
```

### Background Job

**Oban Worker:**
```elixir
defmodule Kanban.Workers.ReleaseExpiredClaims do
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  @impl Oban.Worker
  def perform(_job) do
    case Kanban.Tasks.release_expired_claims() do
      {:ok, count} when count > 0 ->
        Logger.info("Released #{count} expired task claims")
        :ok
      {:ok, 0} ->
        :ok
    end
  end
end
```

**Cron Schedule:**
```elixir
config :kanban, Oban,
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"*/5 * * * *", Kanban.Workers.ReleaseExpiredClaims}
     ]}
  ]
```

### Release Function

**Context Function:**
```elixir
def release_expired_claims do
  now = DateTime.utc_now()

  {count, tasks} = Repo.update_all(
    from(t in Task,
      where: t.status == "in_progress",
      where: t.claim_expires_at < ^now,
      select: [:id, :title]
    ),
    set: [
      status: "open",
      claimed_at: nil,
      claim_expires_at: nil,
      updated_at: now
    ]
  )

  # Broadcast each released task
  Enum.each(tasks, fn task ->
    :telemetry.execute([:kanban, :task, :claim_expired], %{task_id: task.id}, %{released_at: now})
    full_task = get_task!(task.id)
    broadcast_task_change(full_task, :task_claim_expired)
  end)

  {:ok, count}
end
```

## Benefits

### For AI Agents
1. **Resilience**: Agent crashes don't permanently block tasks
2. **Fair Distribution**: Tasks become available to other agents after timeout
3. **No Manual Intervention**: System automatically recovers from failures
4. **Visibility**: Telemetry shows when agents are having issues (frequent expirations)

### For System
1. **Self-Healing**: Automatically recovers from agent failures
2. **Monitoring**: Metrics track claim duration and expiration frequency
3. **Performance**: Indexed queries ensure background job is efficient
4. **Scalability**: Works well with multiple concurrent agents

## Observability

**New Telemetry Events:**
- `[:kanban, :task, :claim_expired]` - Fired when claim expires
- Event metadata includes task_id and released_at timestamp

**New Metrics:**
- Counter: Expired claims released per job run
- Histogram: Task claim duration (claimed_at to completion or expiry)
- Gauge: Claimed tasks nearing expiry (< 10 minutes remaining)

**New Logging:**
- Info level: Task claims with expires_at timestamp
- Info level: Expired claim releases with task ID and claim duration

## Testing Strategy

**Unit Tests:**
1. Test claim sets claimed_at and claim_expires_at
2. Test expired claims are returned by get_next_task()
3. Test release_expired_claims() finds and updates correct tasks
4. Test background job calls release function
5. Test telemetry events are fired

**Integration Tests:**
1. Claim task, set expiry to past, verify becomes available
2. Claim task, verify not available to other agents
3. Wait for expiry, verify auto-released and available
4. Multiple agents claiming different tasks
5. Background job running on schedule

**Manual Testing:**
See task 08, lines 196-200 for complete manual test scenarios.

## Migration Path

**Step 1: Database Migration (Task 02)**
```bash
mix ecto.gen.migration add_task_metadata
# Edit migration to include claimed_at and claim_expires_at
mix ecto.migrate
```

**Step 2: Schema Updates (Task 02)**
Update Task schema to include new fields in changeset.

**Step 3: Context Functions (Task 08)**
Implement get_next_task(), claim_next_task(), and release_expired_claims().

**Step 4: Background Job (Task 08)**
Create Oban worker and configure cron schedule.

**Step 5: API Endpoints (Task 08)**
Update controller actions to use new claim logic.

**Step 6: Testing**
Add tests for expiry logic and background job.

## Configuration

**Oban Setup Required:**
```elixir
# config/config.exs
config :kanban, Oban,
  repo: Kanban.Repo,
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"*/5 * * * *", Kanban.Workers.ReleaseExpiredClaims}
     ]}
  ],
  queues: [maintenance: 10]
```

**Environment Variables:**
None required. Timeout is hardcoded to 60 minutes. Future enhancement could make this configurable.

## Future Enhancements (Out of Scope)

From IMPROVEMENTS.md, these related features are NOT implemented:

1. **Agent Heartbeat**: Extend claim expiry by pinging server
2. **Configurable Timeout**: Per-task or per-agent timeout settings
3. **Manual Extension**: API endpoint to extend claim before expiry
4. **Expiration Alerts**: Alert when tasks expire repeatedly
5. **Claim History**: Track all claim attempts for analytics

## Dependencies

**Task 02 Must Complete First:**
- Task 08 depends on task 02 for the database fields
- Migration in task 02 must include claimed_at and claim_expires_at
- Schema in task 02 must include these fields in changeset

**Oban Dependency:**
- Project must have Oban installed and configured
- If not already present, add to mix.exs: `{:oban, "~> 2.15"}`

## Success Criteria

- [ ] Tasks claimed for > 60 minutes automatically release
- [ ] Background job runs every 5 minutes without errors
- [ ] Released tasks become immediately available to other agents
- [ ] PubSub broadcasts notify all clients of expiration
- [ ] Telemetry events track expiration frequency
- [ ] No performance impact on API endpoints
- [ ] No race conditions when multiple agents claim simultaneously
- [ ] Tests cover all expiry scenarios

## Rollback Plan

If issues arise, can temporarily disable by:

1. **Disable Background Job:**
```elixir
# Comment out cron configuration
# {"*/5 * * * *", Kanban.Workers.ReleaseExpiredClaims}
```

2. **Revert Query Logic:**
```elixir
# Change back to simple status check
where: t.status == "open"  # Instead of checking expiry
```

3. **Future: Remove Feature:**
- Remove claimed_at and claim_expires_at from queries
- Keep database columns for historical data
- Re-enable in future when ready

## Documentation References

- **Full Implementation**: See task 08 (lines 1-686)
- **Database Schema**: See task 02 (lines 40-54, 140-176)
- **Requirements**: See IMPROVEMENTS.md improvement #1
- **API Workflow**: See README.md "The AI Workflow" section
