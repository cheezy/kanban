# API Format

Would you want tasks as JSON, or some other format?

## AI Perspective

From my perspective as an AI agent, JSON is excellent for this use case. Here's why:

### Why JSON Works Well for AI

✅ Pros

- Tool-friendly: Most AI systems have built-in JSON parsing/generation
- Structured & typed: I can validate schemas easily
- Nested data: Perfect for complex fields like acceptance_criteria, technical_context, dependencies
- Standard: Every HTTP client speaks JSON fluently
- Type-safe in Elixir: Phoenix/Ecto handle JSON encoding/decoding well

Example - Creating Tasks from Planning

```http
POST /api/tasks/batch
```

```json
{
  "tasks": [
    {
      "title": "Add API authentication for AI agents",
      "description": "Create token-based auth for AI workflow endpoints",
      "type": "feature",
      "priority": 0,
      "status": "open",
      "acceptance_criteria": [
        "Generate API tokens in user settings",
        "Validate token in API pipeline",
        "Return 401 for invalid tokens"
      ],
      "technical_context": {
        "files_to_modify": [
          "lib/kanban_web/router.ex",
          "lib/kanban_web/api/auth_pipeline.ex"
        ],
        "existing_patterns": "Use Guardian for auth like web session"
      },
      "scope": {
        "in_scope": ["Token generation", "Token validation"],
        "out_of_scope": ["OAuth", "Rate limiting"]
      }
    },
    {
      "title": "Create /api/tasks/ready endpoint",
      "description": "Return unblocked tasks ready to work",
      "type": "feature",
      "priority": 0,
      "depends_on": ["kanban-1"],  // References first task
      "technical_context": {
        "files_to_modify": ["lib/kanban_web/controllers/api/task_controller.ex"]
      }
    }
  ]
}
```

Response Format

```json
{
  "created": [
    {"id": "kanban-1", "title": "Add API authentication...", "status": "open"},
    {"id": "kanban-2", "title": "Create /api/tasks/ready...", "status": "blocked"}
  ],
  "errors": []
}
```

### Recommended: Structured JSON Based on TASKS.md Template

The optimal format combines structure with rich context (see **TASKS.md** for full template):

```json
{
  "title": "Add priority filter to board list view",
  "complexity": "medium",
  "estimated_files": "2-3",
  "description": {
    "why": "Users need to focus on high-priority tasks without manually scanning",
    "what": "Add a dropdown filter for task priority (0-4) in board header",
    "where": "Board list view header, next to existing status filter"
  },
  "acceptance_criteria": [
    "Dropdown shows priorities 0-4 with labels",
    "Filtering updates task list in real-time via LiveView",
    "Filter state persists in URL params"
  ],
  "key_files": [
    {
      "path": "lib/kanban_web/live/board_live.ex",
      "note": "Main LiveView handling board display"
    }
  ],
  "technical_notes": {
    "patterns": ["Use existing filter pattern from status filter"],
    "database": {
      "tables": ["tasks"],
      "migration_needed": true
    },
    "integration_points": {
      "pubsub": false,
      "channels": false
    }
  },
  "verification": {
    "commands": ["mix test test/kanban/boards_test.exs", "mix precommit"],
    "manual_steps": ["Navigate to /boards", "Click priority filter dropdown"],
    "success_indicators": ["Dropdown appears", "Task list updates without reload"]
  },
  "observability": {
    "telemetry_events": [],
    "metrics": ["Could add [:kanban, :filter, :used] counter"],
    "logging": "No logging needed"
  },
  "error_handling": {
    "user_sees": "Graceful degradation if invalid priority",
    "on_failure": "Show all tasks",
    "validation": "Ensure priority is 0-4 or nil"
  },
  "data_examples": {
    "input": {"priority": "3", "status": "in_progress"},
    "query": "from t in Task, where: t.priority == ^priority"
  },
  "common_pitfalls": [
    "Remember to handle nil priority (tasks without priority set)",
    "Avoid N+1 queries - filters happen at DB level"
  ],
  "out_of_scope": [
    "Don't add sorting by priority",
    "Don't modify task card layout"
  ]
}
```

This structured format gives AI everything needed to execute without exploration.

### Alternative: Minimal JSON with Markdown Description

For simpler tasks, a hybrid approach works:

```json
{
  "title": "Add priority filter",
  "description": "## Why\nUsers need to focus...\n\n## Technical Notes\n- Use existing filter pattern",
  "acceptance_criteria": ["Filter shows priorities", "Updates in real-time"],
  "technical_context": {
    "files_to_modify": ["lib/kanban_web/live/board_live.ex"]
  }
}
```

Markdown in description gives human readability, while JSON structure gives AI parseability.

### Other Formats to Consider?

- JSONL (newline-delimited JSON): Good for streaming/batching, but JSON is simpler
- GraphQL: More flexible queries, but adds complexity
- Plain text/Markdown: Human-friendly but harder to parse programmatically

My recommendation: Stick with JSON for the API. It's the sweet spot of structure, simplicity, and AI-friendliness. Does that align with your thinking?
