# GET /api/agent/onboarding

Get comprehensive onboarding information for new AI agents. This endpoint provides everything an agent needs to get started with Stride.

## Authentication

**No authentication required** - This endpoint is public so new agents can access it before obtaining API tokens.

## Request

**Method:** GET
**Endpoint:** `/api/agent/onboarding`
**Parameters:** None

**Accept header:** The response is JSON only. Send `Accept: application/json`,
`Accept: */*`, or no `Accept` header. Any other value, such as `text/html` or
`application/xml`, returns [406 Not Acceptable](#not-acceptable-406-not-acceptable).

## Response

### Success (200 OK)

Returns comprehensive onboarding information. The real response is much longer:
this example shortens long strings with `...` and elides most arrays and
objects.

```json
{
  "version": "1.0",
  "skills_version": "1.0",
  "api_base_url": "https://www.stridelikeaboss.com",
  "⚠️⚠️⚠️_STOP_DO_NOT_PROCEED_UNTIL_SETUP_COMPLETE_⚠️⚠️⚠️": {...},
  "MANDATORY_SETUP_CHECKLIST": {...},
  "SETUP_COMPLETION_CONFIRMATION": {...},
  "required_reading": {...},
  "overview": {
    "description": "Stride is a kanban-based task management system designed for AI agents with integrated workflow hooks.",
    "agent_workflow_pattern": "Agents should work continuously: claim task → complete → ...",
    "workflow_summary": "Ready → Doing → Review → Done",
    "key_features": [...]
  },
  "quick_start": [
    "Windows users: See https://www.stridelikeaboss.com/docs/WINDOWS-SETUP.md for platform-specific setup ...",
    "1. Check if .stride_auth.md exists - if NOT, create by copying the ENTIRE file_templates.stride_auth_md content exactly",
    ...
  ],
  "file_templates": {
    "stride_auth_md": "# Stride API Authentication\n\n...",
    "stride_md": "# Stride Configuration\n\n..."
  },
  "workflow": [
    {
      "name": "claim_task",
      "endpoint": "POST https://www.stridelikeaboss.com/api/tasks/claim",
      "description": "Claim next available task matching your capabilities. ...",
      "returns": "Task data + before_doing hook metadata",
      "required_parameters": ["before_doing_result"],
      "hook_validation": "MANDATORY - Must execute before_doing hook BEFORE calling this endpoint ...",
      "documentation_url": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/post_tasks_claim.md"
    },
    ...
  ],
  "hooks": {
    "description": "Hooks execute on YOUR machine, not the server. Server provides metadata only.",
    "available_hooks": [
      {
        "name": "before_doing",
        "blocking": true,
        "timeout": 600000,
        "when": "Before starting work on a task",
        "typical_use": "Pull latest code"
      },
      ...
    ],
    "environment_variables": [...],
    "execution_flow": [...]
  },
  "api_reference": {
    "base_url": "https://www.stridelikeaboss.com",
    "authentication": "Bearer token in Authorization header",
    "openapi_url": "https://www.stridelikeaboss.com/api/openapi.json",
    "workspace_tokens": {...},
    "endpoints": {
      "discovery": [
        {
          "method": "GET",
          "path": "/api/boards",
          "description": "List the boards this token can use: ...",
          "auth_required": true,
          "documentation_url": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/get_boards.md"
        },
        ...
      ],
      "management": [...],
      "creation": [...]
    }
  },
  "api_schema": {...},
  "task_creation_requirements": {...},
  "claude_code_skills": {...},
  "multi_agent_instructions": {
    "description": "Always-active code completion guidance for AI assistants other than Claude Code. ...",
    "note": "Claude Code users should use the claude_code_skills section above ...",
    "formats": {
      "copilot": {
        "description": "Stride Copilot Plugin — provides 6 Copilot-adapted skills and 4 custom agents via copilot plugin install",
        "installation_unix": "copilot plugin install https://github.com/cheezy/stride-copilot",
        "installation_windows": "copilot plugin install https://github.com/cheezy/stride-copilot",
        "update": "copilot plugin update stride-copilot",
        "plugin_repo": "https://github.com/cheezy/stride-copilot",
        "skills_provided": [...],
        "custom_agents": [...],
        "note": "...",
        "fallback_note": "...",
        "uninstall": "..."
      },
      "codex": {...},
      "continue": {...},
      "cursor": {...},
      "gemini": {...},
      "kimi": {...},
      "opencode": {...},
      "windsurf": {...}
    },
    "safe_installation": [...],
    "installation_warning": "...",
    "usage_notes": [...]
  },
  "common_mistakes_agents_make": {...},
  "first_session_vs_returning": {...},
  "memory_strategy": {...},
  "session_initialization": {...},
  "quick_reference_card": {...},
  "resources": {
    "documentation_url": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/README.md",
    "api_workflow_guide": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/AI-WORKFLOW.md",
    "authentication_guide": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/AUTHENTICATION.md",
    "capabilities_guide": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/AGENT-CAPABILITIES.md",
    "changelog_url": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/CHANGELOG.md",
    "estimation_feedback_guide": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/ESTIMATION-FEEDBACK.md",
    "hook_execution_guide": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/AGENT-HOOK-EXECUTION-GUIDE.md",
    "review_workflow_guide": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/REVIEW-WORKFLOW.md",
    "task_writing_guide": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/TASK-WRITING-GUIDE.md",
    "unclaim_guide": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/UNCLAIM-TASKS.md"
  }
}
```

### Bad Request (400 Bad Request)

Returned when the query string cannot be parsed, for example `?a=%FF` (an
invalid percent-encoding). The body is always JSON, whatever the `Accept`
header says, with a fixed message that never echoes the request:

```json
{
  "error": "Bad Request",
  "message": "The request is malformed and could not be processed."
}
```

Every `/api` route behaves the same way. See
[Errors](README.md#400-for-a-malformed-query-string-or-body) in the API README.

### Not Acceptable (406 Not Acceptable)

Returned when the `Accept` header (or a `_format` query parameter) asks for a
format other than JSON, for example `Accept: text/html`. The body is JSON,
with a fixed message that never echoes the header back:

```json
{
  "error": "Not Acceptable",
  "message": "This API only serves application/json."
}
```

Every `/api` route behaves the same way. See
[Errors](README.md#406-not-acceptable) in the API README.

## Response Structure

### `overview`

High-level description of Stride and its key features for agents.

### `quick_start`

Step-by-step setup instructions, as an array of strings.

### `file_templates`

Complete templates for:

- `.stride_auth.md` - Authentication configuration (DO NOT commit)
- `.stride.md` - Hook configuration (version controlled)

Both templates include:

- Correct base URL for the current environment
- Placeholder values marked with `{{...}}`
- Usage examples

### `workflow`

An array with one object per workflow step (`claim_task`, `complete_task`,
`upload_changed_files`, `mark_reviewed`, `unclaim_task`). Each has:

- `name`
- `endpoint` (method and full URL)
- `description`
- `returns`
- `required_parameters`, where the step needs any
- `hook_validation`, on every step except `unclaim_task` (it says how the
  step's hook result is checked, or that the step is not a hook endpoint)
- `documentation_url`, a link to the detailed page

### `hooks`

Complete hook system information:

- Description of client-side execution
- All four hook points with metadata
- Environment variables available to hooks
- Execution flow explanation

### `multi_agent_instructions`

Always-active code completion guidance for AI assistants other than Claude Code:

- `description` and `note` — how this complements Claude Code Skills
- `formats` — one entry per assistant: `copilot`, `codex`, `continue`,
  `cursor`, `gemini`, `kimi`, `opencode` and `windsurf`
- `safe_installation`, `installation_warning` and `usage_notes` — how to
  install without overwriting existing configuration

Each format entry has a `description` and installation commands for
Unix/Linux/macOS (`installation_unix`) and Windows (`installation_windows`).
The other keys depend on how that assistant is set up:

- Plugin formats (`copilot`, `codex`, `gemini`, `opencode`) name their
  repository (`plugin_repo` or `extension_repo`), the skills and agents they
  provide, and a `fallback_note` for manual installation.
- Instruction-file formats (`continue`, `cursor`, `kimi`, `windsurf`) give a
  `file_path` and a `token_limit`. `kimi` also gives a `download_url`.

**Note**: Claude Code users should use the `claude_code_skills` section instead for comprehensive workflow enforcement. The recommended entry point for all platforms is the `stride-workflow` orchestrator skill, which walks through the complete task lifecycle (claim → explore → implement → review → complete) in a single skill.

### `api_reference`

`base_url`, the `authentication` scheme, and `openapi_url` — the absolute URL of
the machine-readable OpenAPI 3.1 spec ([GET /api/openapi.json](get_openapi_json.md)) —
plus a list of every `/api` route in the router, organized in three groups
(a test fails when a route is missing):

- Discovery endpoints (this onboarding payload, the OpenAPI spec, boards, and
  reading tasks, their trees, dependencies, dependents and comments)
- Management endpoints (claim, complete, review, after_goal, comments and the
  MCP server)
- Creation endpoints (create tasks and goals, and update a task)

Each endpoint includes:

- `method` and `path`
- `description`
- `auth_required`, which is `false` only for this payload and the OpenAPI spec
- `documentation_url`, a link to the detailed page

Some endpoints also carry `required_parameters`, `hook_validation_required`
and `returns_hooks` (the hooks the response includes). For
`PATCH /api/tasks/:id/complete`, `required_parameters` is the same list the
`complete_task` workflow step publishes, and a test sends a completion built
only from the payload's own examples to check that the server accepts it.

`workspace_tokens` explains workspace-scoped tokens: who creates them, the
`X-Stride-Board` header and `board_id` parameter that name the board each
request acts on, the `400` and `404` responses, and
[GET /api/boards](get_boards.md), which lists the boards a token can use.

### `resources`

Links to additional documentation and resources.

### `api_schema`

Machine-readable schema for the task fields accepted by the creation
endpoints, split into `task_fields` (scalar/array fields) and
`embedded_objects` (structured fields like `key_files`, `verification_steps`,
and `testing_strategy`).

Among the `task_fields`/`embedded_objects` is `technical_details` — an
**optional free-form JSON object** for arbitrary technical information. Unlike
`testing_strategy`, it has **no fixed `valid_keys`**: any keys and values
(including nested objects and arrays) are accepted. Omitting it stores an empty
object (`{}`). Example:

```json
"technical_details": {
  "db_migration": "Adds a technical_details :map column",
  "rollback": { "steps": ["Drop the column"] }
}
```

## Example Usage

### Get onboarding info

```bash
curl https://www.stridelikeaboss.com/api/agent/onboarding | jq '.'
```

### Extract quick start steps

```bash
curl -s https://www.stridelikeaboss.com/api/agent/onboarding | jq -r '.quick_start[]'
```

### Get .stride_auth.md template

**Unix/Linux/macOS:**

```bash
curl -s https://www.stridelikeaboss.com/api/agent/onboarding | \
  jq -r '.file_templates.stride_auth_md' > .stride_auth.md
```

**Windows PowerShell:**

```powershell
(Invoke-WebRequest -Uri "https://www.stridelikeaboss.com/api/agent/onboarding").Content | `
  ConvertFrom-Json | Select -ExpandProperty file_templates | `
  Select -ExpandProperty stride_auth_md | `
  Out-File -FilePath .stride_auth.md -Encoding utf8
```

**Alternative (with jq installed via chocolatey):**

```powershell
curl -s https://www.stridelikeaboss.com/api/agent/onboarding | `
  jq -r '.file_templates.stride_auth_md' | `
  Out-File -FilePath .stride_auth.md -Encoding utf8
```

### Get .stride.md template

**Unix/Linux/macOS:**

```bash
curl -s https://www.stridelikeaboss.com/api/agent/onboarding | \
  jq -r '.file_templates.stride_md' > .stride.md
```

**Windows PowerShell:**

```powershell
(Invoke-WebRequest -Uri "https://www.stridelikeaboss.com/api/agent/onboarding").Content | `
  ConvertFrom-Json | Select -ExpandProperty file_templates | `
  Select -ExpandProperty stride_md | `
  Out-File -FilePath .stride.md -Encoding utf8
```

### List all available hooks

**Unix/Linux/macOS:**

```bash
curl -s https://www.stridelikeaboss.com/api/agent/onboarding | \
  jq '.hooks.available_hooks'
```

**Windows PowerShell:**

```powershell
(Invoke-WebRequest -Uri "https://www.stridelikeaboss.com/api/agent/onboarding").Content | `
  ConvertFrom-Json | Select -ExpandProperty hooks | `
  Select -ExpandProperty available_hooks | ConvertTo-Json
```

### Get workflow steps

```bash
curl -s https://www.stridelikeaboss.com/api/agent/onboarding | \
  jq '.hooks.execution_flow'
```

## Use Cases

### First-Time Agent Setup

1. Call this endpoint to get onboarding info
2. Extract file templates and save them locally
3. Replace placeholders with actual values
4. Follow quick_start steps
5. Begin working with tasks

### Agent Development

Use this endpoint to:

- Understand the complete API structure
- See all available hooks and their metadata
- Get correct endpoint URLs for current environment
- Access documentation links

### Automated Onboarding

Agents can programmatically:

- Fetch configuration templates
- Validate their setup
- Discover available endpoints
- Learn the workflow without manual documentation

### Planning and Uploading Multiple Goals

A common onboarding workflow is to analyze a project and upload a comprehensive plan with multiple goals. Use the batch endpoint for this:

```bash
# 1. Get onboarding info and understand the system
curl https://www.stridelikeaboss.com/api/agent/onboarding

# 2. Analyze the project and create a plan with multiple goals

# 3. Upload all goals in one request
curl -X POST \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "goals": [
      {
        "title": "Setup authentication system",
        "type": "goal",
        "priority": "high",
        "tasks": [
          {"title": "Add JWT library", "type": "work"},
          {"title": "Create auth endpoints", "type": "work"}
        ]
      },
      {
        "title": "User profile management",
        "type": "goal",
        "priority": "medium",
        "tasks": [
          {"title": "Profile schema", "type": "work"},
          {"title": "Profile UI", "type": "work"}
        ]
      }
    ]
  }' \
  https://www.stridelikeaboss.com/api/tasks/batch
```

**Benefits:**

- Upload entire project plan in one API call
- Establish work structure before claiming individual tasks
- Clear visibility of all planned work
- Dependencies automatically enforced across goals

See [POST /api/tasks/batch](post_tasks_batch.md) for complete documentation on batch uploads.

## Notes

- **No authentication required** - Accessible without API token
- **Dynamic base URL** - Automatically includes correct server URL
- **Always current** - Hook information pulled from live system configuration
- **Self-documenting** - All endpoint paths and documentation links included
- **Environment-aware** - Templates include correct URLs for dev/production

## Best Practices

### Reload with Each New Session

**⚠️ IMPORTANT:** Both AI agents and humans should reload the onboarding endpoint at the start of each new work session.

**Why reload?**
- Claude Code skills may be updated with bug fixes or improvements
- API documentation URLs may change
- Hook configurations may be modified
- New workflow features may be added
- Base URLs or endpoints may be updated

**When to reload:**
- At the start of each new Claude Code session
- After any system maintenance or updates
- When starting work on a new project or board
- If you encounter unexpected behavior

**How to reload:**
```bash
# Fetch latest onboarding information
curl -s https://www.stridelikeaboss.com/api/agent/onboarding | jq '.'

# Update your Claude Code skills if they've changed
# (Check the claude_code_skills section)
```

This ensures you're always working with the latest skills, documentation, and system configuration.

## See Also

- [README.md](README.md) - Complete API documentation
- [POST /api/tasks/claim](post_tasks_claim.md) - Claim your first task
- [AI-WORKFLOW.md](../AI-WORKFLOW.md) - Detailed workflow guide
