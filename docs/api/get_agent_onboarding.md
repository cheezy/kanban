# GET /api/agent/onboarding

Get comprehensive onboarding information for new AI agents. This endpoint provides everything an agent needs to get started with Stride.

## Authentication

**No authentication required** - This endpoint is public so new agents can access it before obtaining API tokens.

## Request

**Method:** GET
**Endpoint:** `/api/agent/onboarding`
**Parameters:** None

## Response

### Success (200 OK)

Returns comprehensive onboarding information:

```json
{
  "version": "1.0",
  "api_base_url": "https://www.stridelikeaboss.com",
  "overview": {
    "description": "Stride is a kanban-based task management system...",
    "workflow_summary": "Ready → Doing → Review → Done",
    "key_features": [...]
  },
  "quick_start": [
    "1. Get your API token from your user/project manager",
    "2. Create .stride_auth.md with authentication details",
    ...
  ],
  "file_templates": {
    "stride_auth_md": "# Stride API Authentication\n\n...",
    "stride_md": "# Stride Configuration\n\n..."
  },
  "workflow": {
    "claim_task": {
      "endpoint": "POST https://www.stridelikeaboss.com/api/tasks/claim",
      "description": "Claim next available task",
      "returns": "Task data + before_doing hook metadata",
      "documentation_url": "docs/api/post_tasks_claim.md"
    },
    ...
  },
  "hooks": {
    "description": "Hooks execute on YOUR machine, not the server...",
    "available_hooks": [
      {
        "name": "before_doing",
        "blocking": true,
        "timeout": 60000,
        "when": "Before starting work on a task",
        "typical_use": "Setup workspace, pull latest code"
      },
      ...
    ],
    "environment_variables": [...],
    "execution_flow": [...]
  },
  "api_reference": {
    "base_url": "https://www.stridelikeaboss.com",
    "authentication": "Bearer token in Authorization header",
    "endpoints": {
      "discovery": [...],
      "management": [...],
      "creation": [...]
    }
  },
  "multi_agent_instructions": {
    "description": "Always-active code completion guidance for other AI assistants",
    "formats": {
      "copilot": {
        "file_path": ".github/copilot-instructions.md",
        "description": "GitHub Copilot instructions",
        "download_url": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/copilot-instructions.md",
        "installation_unix": "curl -o .github/copilot-instructions.md [download_url]",
        "installation_windows": "Invoke-WebRequest -Uri \"[download_url]\" -OutFile .github/copilot-instructions.md"
      },
      "cursor": {
        "file_path": ".cursorrules",
        "description": "Cursor rules",
        "download_url": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/cursorrules.txt",
        "installation_unix": "curl -o .cursorrules [download_url]",
        "installation_windows": "Invoke-WebRequest -Uri \"[download_url]\" -OutFile .cursorrules"
      },
      "windsurf": {
        "file_path": ".windsurfrules",
        "description": "Windsurf Cascade rules",
        "download_url": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/windsurfrules.txt",
        "installation_unix": "curl -o .windsurfrules [download_url]",
        "installation_windows": "Invoke-WebRequest -Uri \"[download_url]\" -OutFile .windsurfrules"
      },
      "aider": {
        "file_path": ".aider.conf.yml",
        "description": "Aider configuration",
        "download_url": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/aider.conf.yml",
        "installation_unix": "curl -o .aider.conf.yml [download_url]",
        "installation_windows": "Invoke-WebRequest -Uri \"[download_url]\" -OutFile .aider.conf.yml"
      },
      "continue": {
        "file_path": ".continue/config.json",
        "description": "Continue.dev configuration",
        "download_url": "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/multi-agent-instructions/continue-config.json",
        "installation_unix": "mkdir -p .continue && curl -o .continue/config.json [download_url]",
        "installation_windows": "New-Item -ItemType Directory -Force -Path .continue; Invoke-WebRequest -Uri \"[download_url]\" -OutFile .continue/config.json"
      }
    }
  },
  "resources": {
    "documentation_url": "https://www.stridelikeaboss.com/docs/api/README.md",
    "api_workflow_guide": "https://www.stridelikeaboss.com/docs/WIP/AI-WORKFLOW.md",
    "changelog_url": "https://www.stridelikeaboss.com/changelog"
  }
}
```

## Response Structure

### `overview`

High-level description of Stride and its key features for agents.

### `quick_start`

Step-by-step instructions to get started (5 steps).

### `file_templates`

Complete templates for:

- `.stride_auth.md` - Authentication configuration (DO NOT commit)
- `.stride.md` - Hook configuration (version controlled)

Both templates include:

- Correct base URL for the current environment
- Placeholder values marked with `{{...}}`
- Usage examples

### `workflow`

Details for each workflow step with:

- Endpoint URL
- Description
- What it returns
- Link to detailed documentation

### `hooks`

Complete hook system information:

- Description of client-side execution
- All four hook points with metadata
- Environment variables available to hooks
- Execution flow explanation

### `multi_agent_instructions`

Always-active code completion guidance for AI assistants other than Claude Code:

- **Description**: Complementary approach to Claude Code Skills
- **Formats**: Five AI assistant formats (Copilot, Cursor, Windsurf, Aider, Continue.dev)
- **Download URLs**: Direct links to instruction files hosted on GitHub
- **Installation**: Platform-specific download commands (Unix/Linux/macOS and Windows)

Each format includes:

- File path where instructions should be placed
- Description of the AI assistant
- Download URL for the instruction file
- Installation command for Unix/Linux/macOS (using curl)
- Installation command for Windows (using PowerShell)
- Token limit information

**Note**: Claude Code users should use the `claude_code_skills` section instead for comprehensive workflow enforcement.

### `api_reference`

Organized list of all API endpoints:

- Discovery endpoints (browse tasks)
- Management endpoints (claim, complete, review)
- Creation endpoints (create tasks/goals)

Each endpoint includes:

- HTTP method
- Full path
- Description
- Which hooks it returns (if any)
- Link to detailed documentation

### `resources`

Links to additional documentation and resources.

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
- [AI-WORKFLOW.md](../WIP/AI-WORKFLOW.md) - Detailed workflow guide
