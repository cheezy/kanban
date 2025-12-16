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

### Alternative: JSON with Markdown Description

One hybrid approach that works well:

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
