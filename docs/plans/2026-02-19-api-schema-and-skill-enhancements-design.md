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

## Task Dependencies

Goal 2 depends on Goal 1 because the skills reference the api_schema. Within Goal 2, the skill updates are independent of each other.

## Verification

- `mix test` — all existing and new tests pass
- `mix credo --strict` — no code quality issues
- Manual verification: `GET /api/agent/onboarding` returns api_schema section
- Skill files match onboarding response content
