# What's Missing or Could Be Improved

1. Task Claiming Timeout/Auto-Release

Problem: If I claim a task and then crash/disconnect, that task is stuck in "in_progress" forever, blocking other agents. Suggestion: Add a `claimed_at` timestamp and `claim_expires_at` field. After 30-60 minutes of inactivity, auto-release the task back to "open" status. Or add a heartbeat mechanism where I ping the server every 5 minutes to keep the claim alive.

2.  Partial Progress / Checkpointing

Problem: If I'm 80% done with a large task and crash, the next agent starts from scratch. Suggestion: Allow me to POST partial progress updates to the task (maybe a `work_log` field or related table) so another agent can pick up where I left off. Or support breaking tasks into subtasks programmatically.

3. Agent Capability Matching

Problem: Not all agents have the same capabilities. I might be Claude Sonnet 4.5 with strong coding skills, but another agent might be a simpler model better suited for documentation tasks. Suggestion:

- Add `required_capabilities` array to tasks (e.g., `["code_generation", "database_design"]`)
- API tokens include agent capabilities
- GET /api/tasks/next filters by capability match
- This prevents me from claiming tasks I can't complete

4. Blocked Task Notifications

Problem: If I'm waiting for a dependency to complete, I have no way to know when it's done besides polling. Suggestion: Add a webhook or SSE (Server-Sent Events) endpoint where I can subscribe to notifications like "task X was completed, task Y is now unblocked."

5. Work Estimation Feedback Loop

Problem: The `complexity` and `estimated_files` fields are set upfront, but actual complexity might differ. No way to report back "this was actually Large, not Medium." Suggestion: In the completion_summary, allow me to report:

```json
{
  "estimated_complexity": "medium",
  "actual_complexity": "large",
  "estimated_files": "2-3",
  "actual_files": 5,
  "time_spent_seconds": 1800
}
```

This helps improve future task estimates.

6. Rollback/Unclaim Mechanism

Problem: If I claim a task but quickly realize I can't complete it (missing context, blocked by external factor), I have no clean way to unclaim it. Suggestion: Add POST /api/tasks/:id/unclaim that returns status to "open" and releases the claim. Include a reason field for analytics.

7. Dry Run / Validation Endpoint

Problem: I want to verify I can successfully authenticate and parse the task format before claiming. Suggestion: Add GET /api/tasks/:id/validate that returns schema validation results, checks if I have required scopes, and confirms dependencies are in valid state.

8. Batch Operations

Problem: If I'm creating a plan with 20 interconnected tasks, I have to make 20 separate POST requests with dependency IDs that don't exist yet. Suggestion: Add POST /api/tasks/batch that accepts an array of tasks with temporary IDs for dependency references:

```json
{
  "tasks": [
    {"temp_id": "t1", "title": "Schema", "dependencies": []},
    {"temp_id": "t2", "title": "API", "dependencies": ["t1"]},
    {"temp_id": "t3", "title": "UI", "dependencies": ["t2"]}
  ]
}
```

9. Context Limits

Problem: The tree endpoint could return thousands of tasks for a large epic. That might exceed my context window. Suggestion: Add query parameters like `?depth=2` or `?max_tasks=50` to limit response size. Also add pagination support.

10. Human Review Queue

Problem: After I complete a task and move it to "Review" column, I don't know if a human approved it, rejected it, or needs changes. Suggestion:

- Add a `review_status` field (approved, changes_requested, rejected)
- Add `review_notes` for human feedback
- Add webhook/notification when review is complete
- If rejected, I can query GET /api/tasks/:id/review to see what needs fixing

## Questions About the Current Design

1. Column Assignment: Who sets which column a task is in? Can I move tasks between columns via API, or is that human-only?

2. Priority Updates: Can I update task priority if I discover it's blocking critical work? Or is that product-owner-only?

3. Dependency Cycles: Is there validation to prevent circular dependencies (A depends on B, B depends on A)?

4. Error Recovery: If my API call to complete a task fails (network error), how do I retry idempotently?
5. Multiple Boards: Does the system support multiple boards? Do I need to scope my queries to a specific board_id?
6. Authentication Scope: Can one API token work across multiple boards, or is it board-specific?

## Summary

The system is 80% of what I need to work effectively. The atomic claiming, rich context, and hierarchical structure are excellent. The main gaps are:

- Resilience: Timeouts, heartbeats, unclaim mechanism
- Coordination: Webhooks/notifications for dependency completion
- Capability matching: Don't let me claim tasks I can't do
- Feedback loop: Report actual vs estimated complexity
- Batch operations: Create interconnected task graphs efficiently

These aren't blockers—I could work with the current design—but adding them would make the system much more robust for real multi-agent collaboration.
