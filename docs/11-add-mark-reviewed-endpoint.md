# Add Mark Reviewed API Endpoint

**Complexity:** Small | **Est. Files:** 2-3

## Description

**WHY:** After tasks are reviewed in the Review column, they need intelligent routing based on the review outcome. Approved tasks should move to Done, while tasks needing changes should return to Doing for rework. This eliminates polling and provides explicit human-AI communication.

**WHAT:** Implement mark_reviewed function and PATCH /api/tasks/:id/mark_reviewed endpoint that intelligently routes tasks based on review_status field. Approved tasks move to Done column, rejected/changes-requested tasks move back to Doing column.

**WHERE:** Tasks context, API controller

## Acceptance Criteria

- [x] Tasks.mark_reviewed/2 function created with conditional routing logic
- [x] PATCH /api/tasks/:id/mark_reviewed endpoint added
- [x] If review_status = "approved": Task moved to Done column, status set to :completed
- [x] If review_status = "changes_requested" or "rejected": Task moved to Doing column, status remains :in_progress
- [x] reviewed_by_id field populated from user
- [x] PubSub broadcasts appropriate event based on outcome
- [x] Dependent tasks unblocked when task moves to Done
- [x] Tests cover all review status scenarios
- [x] Only tasks in Review column can be marked reviewed
- [x] Error handling for missing or invalid review_status
- [x] Supports both numeric IDs and identifiers (e.g., "W14")

## Key Files Modified

- `lib/kanban/tasks.ex` - Added mark_reviewed/2, move_to_done/3, move_to_doing/3 functions
- `lib/kanban_web/controllers/api/task_controller.ex` - Added mark_reviewed action
- `lib/kanban_web/router.ex` - Added PATCH /api/tasks/:id/mark_reviewed route
- `test/kanban_web/controllers/api/task_controller_test.exs` - Added comprehensive tests

## Technical Notes

**Patterns Followed:**
- Conditional routing based on review_status atom value
- Separate helper functions for Done and Doing routing
- Ecto.Changeset for validation and updates
- PubSub broadcasts for real-time UI updates
- Telemetry events for observability

**Database/Schema:**
- Tables: tasks, columns (to get Done and Doing columns)
- Migrations needed: No (fields already exist)
- Fields used:
  - review_status (string enum) - drives routing logic
  - column_id (integer) - updated to Done or Doing column ID
  - status (atom) - set to :completed for approved, :in_progress for rejected
  - completed_at (utc_datetime) - set when approved
  - reviewed_by_id (integer) - set to current user ID
  - position (integer) - updated for target column

**Integration Points:**
- [x] PubSub broadcasts: Different events for approved vs rejected
- [x] Phoenix Channels: Notify all board subscribers
- [x] Dependency unlocking: Only when task moves to Done (approved)
- [x] Telemetry: Track review outcomes for analytics

## Workflow

### Approved Review Flow
```
1. Human reviews task in Review column
2. Human sets review_status = "approved"
3. Human notifies AI review is complete
4. AI calls PATCH /api/tasks/:id/mark_reviewed
5. System moves task from Review → Done
6. System sets status = :completed
7. System sets completed_at timestamp
8. System unblocks dependent tasks
9. System broadcasts {:task_completed, task}
```

### Rejected/Changes Requested Flow
```
1. Human reviews task in Review column
2. Human sets review_status = "changes_requested" or "rejected"
3. Human adds review_notes explaining what to fix
4. Human notifies AI review is complete
5. AI calls PATCH /api/tasks/:id/mark_reviewed
6. System moves task from Review → Doing
7. System keeps status = :in_progress
8. System broadcasts {:task_returned_to_doing, task}
9. AI reads review_notes field for guidance
10. AI makes changes and completes task again
```

## API Examples

**Mark Reviewed (Approved):**
```bash
curl -X PATCH http://localhost:4000/api/tasks/W16/mark_reviewed \
  -H "Authorization: Bearer stride_dev_xyz..." \
  -H "Content-Type: application/json"
```

**Response (Approved):**
```json
{
  "data": {
    "id": 16,
    "identifier": "W16",
    "title": "Add task completion tracking",
    "status": "completed",
    "review_status": "approved",
    "column_id": 5,
    "completed_at": "2025-12-27T10:30:00Z",
    "reviewed_by_id": 1
  }
}
```

**Response (Changes Requested):**
```json
{
  "data": {
    "id": 16,
    "identifier": "W16",
    "title": "Add task completion tracking",
    "status": "in_progress",
    "review_status": "changes_requested",
    "review_notes": "Please add error handling for edge cases",
    "column_id": 3,
    "reviewed_by_id": 1
  }
}
```

**Error Responses:**
```json
// Task not in Review column
{
  "error": "Task must be in Review column to mark as reviewed"
}

// Review status not set
{
  "error": "Task must have a review status before being marked as reviewed"
}

// Invalid review status
{
  "error": "Invalid review status. Must be 'approved', 'changes_requested', or 'rejected'"
}
```

## Observability

- [x] Telemetry event: `[:kanban, :api, :task_marked_done]` - when approved
- [x] Telemetry event: `[:kanban, :api, :task_returned_to_doing]` - when rejected
- [x] Telemetry event: `[:kanban, :task, :completed]` - when approved
- [x] Telemetry event: `[:kanban, :task, :returned_to_doing]` - when rejected
- [x] Logging: Log outcome at info level with task ID and reviewer
- [x] Metrics: Counter of review outcomes by status

## Error Handling

- Returns 403: "Task does not belong to this board"
- Returns 422: "Task must be in Review column to mark as reviewed"
- Returns 422: "Task must have a review status before being marked as reviewed"
- Returns 422: "Invalid review status. Must be 'approved', 'changes_requested', or 'rejected'"
- On failure: Task status and column remain unchanged

## Benefits

### For AI Agents
- Explicit notification eliminates polling
- Clear routing based on review outcome
- Can read review_notes for guidance on changes
- Automatic return to Doing for rework

### For Humans
- Simple workflow: set status, notify agent
- review_notes provide structured feedback
- Real-time task movement based on decision
- Clear audit trail of reviews

### For System
- Reduces API calls (no polling)
- Clear telemetry for review analytics
- PubSub keeps UI updated in real-time
- Backwards compatible (mark_done still works)

## Migration from mark_done

The old `mark_done` endpoint is preserved but deprecated. It always moves tasks to Done without checking review status.

**New Workflow (Recommended):**
```bash
# Human sets review_status in UI, then notifies agent
curl -X PATCH /api/tasks/:id/mark_reviewed
```

**Old Workflow (Deprecated):**
```bash
# Always moves to Done, ignores review_status
curl -X PATCH /api/tasks/:id/mark_done
```

## Future Enhancements (Out of Scope)

- Auto-assign reviewers based on task type
- Review SLA tracking and notifications
- Batch review operations
- Review templates and checklists
- AI-suggested review priorities

## Success Criteria

- [x] mark_reviewed endpoint implemented
- [x] Conditional routing based on review_status
- [x] Approved tasks → Done column
- [x] Rejected tasks → Doing column
- [x] Telemetry events for both paths
- [x] All tests passing (921 tests)
- [x] Documentation updated
- [x] Backwards compatible with mark_done

## Implementation Summary

The mark_reviewed endpoint successfully implements intelligent task routing based on human review outcomes. It eliminates polling, provides clear feedback mechanisms, and maintains backwards compatibility while offering a superior workflow for human-AI collaboration.
