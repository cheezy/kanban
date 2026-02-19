# API Field Reference Schema & Skill Enhancements

**Date:** 2026-02-19
**Problem:** Agents make incorrect API calls (wrong field values, bad formats) when interacting with Stride, wasting round-trips and time.
**Solution:** Add a machine-readable field reference to the onboarding endpoint and enhance skills with inline validation guidance.

## Problem Analysis

The most common agent mistakes fall into two categories:

1. **Field value mistakes** (most prevalent): Invalid enum values, wrong capability names, bad dependency formats, incorrectly structured embedded objects (verification_steps as strings, key_files missing required fields)
2. **Structural format issues**: Wrong root keys (`"data"` instead of `"task"`, `"tasks"` instead of `"goals"`), missing hook results, wrong hook result format

The API has robust validation and returns helpful error messages with documentation links, but agents make these mistakes because they lack a concise, machine-readable reference they can consult *before* constructing API calls.

## Design

### Goal 1: Add API Field Reference Schema to Onboarding Endpoint

Add a new `api_schema` key to the onboarding response in `AgentJSON.onboarding/1`. This is a lightweight field dictionary — not a full OpenAPI spec.

#### Structure

```json
{
  "api_schema": {
    "description": "Field reference for Stride API. Consult before constructing API requests.",
    "request_formats": {
      "create_task": {"root_key": "task", "example": {"task": {"title": "...", "type": "work"}}},
      "batch_create": {"root_key": "goals", "example": {"goals": [{"title": "...", "type": "goal", "tasks": [...]}]}},
      "claim_task": {"root_key": null, "required_body": {"agent_name": "string", "before_doing_result": "hook_result_format"}},
      "complete_task": {"root_key": null, "required_body": {"agent_name": "string", "time_spent_minutes": "integer", "completion_notes": "string", "after_doing_result": "hook_result_format", "before_review_result": "hook_result_format"}}
    },
    "hook_result_format": {
      "exit_code": {"type": "integer", "required": true, "description": "0 for success, non-zero for failure"},
      "output": {"type": "string", "required": true, "description": "stdout/stderr output from hook execution"},
      "duration_ms": {"type": "integer", "required": true, "description": "How long the hook took to execute in milliseconds"}
    },
    "task_fields": {
      "title": {"type": "string", "required": true, "description": "Short task description"},
      "type": {"type": "enum", "values": ["work", "defect", "goal"], "required": true},
      "priority": {"type": "enum", "values": ["low", "medium", "high", "critical"], "required": true},
      "complexity": {"type": "enum", "values": ["small", "medium", "large"], "required": false},
      "status": {"type": "enum", "values": ["open", "in_progress", "completed", "blocked"], "read_only": true},
      "review_status": {"type": "enum", "values": ["pending", "approved", "changes_requested", "rejected"], "read_only": true},
      "needs_review": {"type": "boolean", "required": false, "default": false},
      "description": {"type": "string", "required": false, "description": "WHY + WHAT + WHERE"},
      "acceptance_criteria": {"type": "string", "required": false, "description": "Newline-separated string"},
      "patterns_to_follow": {"type": "string", "required": false, "description": "Newline-separated string"},
      "why": {"type": "string", "required": false},
      "what": {"type": "string", "required": false},
      "where_context": {"type": "string", "required": false},
      "dependencies": {"type": "array_of_strings", "required": false, "description": "Task identifiers like [\"W45\", \"W46\"] or array indices [0, 1] within a goal"},
      "pitfalls": {"type": "array_of_strings", "required": false},
      "technology_requirements": {"type": "array_of_strings", "required": false},
      "security_considerations": {"type": "array_of_strings", "required": false},
      "out_of_scope": {"type": "array_of_strings", "required": false}
    },
    "embedded_objects": {
      "key_files": {
        "type": "array_of_objects",
        "required_fields": {
          "file_path": "string (relative path, no leading / or ..)",
          "position": "integer >= 0"
        },
        "optional_fields": {
          "note": "string"
        },
        "example": {"file_path": "lib/kanban/tasks.ex", "note": "Add query function", "position": 0}
      },
      "verification_steps": {
        "type": "array_of_objects",
        "NOT_strings": "This MUST be an array of objects, NOT an array of strings",
        "required_fields": {
          "step_type": "string ('command' or 'manual' only)",
          "step_text": "string (the command or instruction)",
          "position": "integer >= 0"
        },
        "optional_fields": {
          "expected_result": "string"
        },
        "example": {"step_type": "command", "step_text": "mix test", "expected_result": "All tests pass", "position": 0}
      },
      "testing_strategy": {
        "type": "object",
        "description": "JSON object with string or array-of-strings values",
        "valid_keys": ["unit_tests", "integration_tests", "manual_tests", "edge_cases", "coverage_target"],
        "example": {
          "unit_tests": ["Test login with valid credentials", "Test login with invalid credentials"],
          "edge_cases": ["Empty password", "SQL injection attempt"],
          "coverage_target": "100% for auth module"
        }
      }
    },
    "valid_capabilities": [
      "api_design", "code_generation", "code_review", "database_design",
      "debugging", "devops", "documentation", "file_operations", "git",
      "performance_optimization", "refactoring", "security_analysis",
      "testing", "ui_design", "ui_implementation", "web_browsing"
    ]
  }
}
```

#### Implementation

- Add a private `api_schema/0` function in `AgentJSON` that returns the schema map
- Include it in the `onboarding/1` response as `api_schema: api_schema()`
- Write tests verifying the schema is present and contains all expected sections

### Goal 2: Enhance Stride Skills with Inline Field Guidance

Each skill gets targeted additions relevant to its workflow, plus a consistent footer.

#### stride-creating-tasks (highest priority)

Add these sections:

1. **Field Quick Reference** — inline table of enum fields with valid values
2. **Embedded Object Formats** — explicit examples for verification_steps, key_files, testing_strategy with "WRONG vs RIGHT" examples
3. **Common Mistakes** — before/after examples of the most frequent errors
4. **Footer** — pointer to api_schema and API docs

#### stride-creating-goals

Add these sections:

1. **Field Quick Reference** — same enum table
2. **Dependency Format** — explicit examples (indices within goal vs identifiers for existing tasks)
3. **Root Key Reminder** — "WRONG vs RIGHT" for `"tasks"` vs `"goals"`
4. **Footer**

#### stride-claiming-tasks

Add these sections:

1. **Hook Result Format** — explicit field types and example
2. **Claim Request Checklist** — required fields for the claim request body
3. **Footer**

#### stride-completing-tasks

Add these sections:

1. **Completion Request Format** — explicit body format with all required fields
2. **Hook Result Reminder** — same format reference
3. **Footer**

#### Consistent Footer (all skills)

```
---
**References:** For the full field reference, see `api_schema` in the onboarding response
(`GET /api/agent/onboarding`). For endpoint details, see the
[API Reference](https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/README.md).
```

#### Implementation

- Edit each SKILL.md file to add the new sections
- Update the skill content strings in `AgentJSON` to match the updated SKILL.md files
- Write/update tests for the onboarding response to verify updated skills are served

### Goal 3: Add Skill Versioning and Staleness Detection

Once onboarded, agents use whatever SKILL.md files are on disk and never re-check for updates. When skills are enhanced (Goal 2), previously onboarded agents keep using stale content. This goal adds a lightweight versioning mechanism so agents automatically detect and update stale skills during normal workflow.

#### Design

**Server side:**
- Add a `skills_version` string (e.g., `"1.0"`) to the onboarding response alongside the existing `version` field
- Bump `skills_version` whenever skill content changes
- Include `current_skills_version` in task API responses (`/api/tasks/next`, `/api/tasks/claim`, `/api/tasks/:id/complete`)
- When the agent provides its `skills_version` (via query param or request body) and it doesn't match the server's current version, include a `skills_update_required` object in the response with instructions

**Agent side (skills update):**
- Each Stride skill stores its version locally (in the SKILL.md frontmatter or a companion file)
- When claiming/completing tasks, the agent sends its `skills_version`
- If the response contains `skills_update_required`, the agent calls `GET /api/agent/onboarding` and re-installs all skills before retrying the original action

**Staleness response format:**
```json
{
  "task": { ... },
  "skills_update_required": {
    "current_version": "1.1",
    "your_version": "1.0",
    "action": "Call GET /api/agent/onboarding and re-install all skills from claude_code_skills.available_skills before continuing.",
    "reason": "Your local skills are outdated. Updated skills contain improved field validation guidance that will help you make correct API calls."
  }
}
```

**Version tracking:**
- The `skills_version` is a simple string managed in `AgentJSON` or application config
- Bumped manually when skill content changes (no automatic detection needed)
- Agents compare strings for equality — no semantic versioning parsing required

#### Implementation

- Add `skills_version` to the onboarding response and `AgentJSON`
- Accept `skills_version` param in task API endpoints (next, claim, complete)
- Return `skills_update_required` when versions don't match
- Update all four Stride skills to include version in frontmatter and send it with API calls
- Write tests for version checking and staleness responses

## Task Dependencies

- Goal 2 depends on Goal 1 because the skills reference the api_schema
- Goal 3 depends on Goal 2 because it versions the enhanced skills
- Within Goal 2, the skill updates are independent of each other
- Within Goal 3, the server-side version tracking must be built before the skill updates

## Verification

- `mix test` — all existing and new tests pass
- `mix credo --strict` — no code quality issues
- Manual verification: `GET /api/agent/onboarding` returns api_schema section and skills_version
- Skill files match onboarding response content
- Task API responses include current_skills_version
- Stale version triggers skills_update_required in responses
