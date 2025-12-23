# Add GET /api/agent/info Endpoint for Agent Documentation

**Complexity:** Small | **Est. Files:** 2-3

## Description

**WHY:** AI agents need to understand how the Stride system works, what's expected of them, workflow requirements, and system conventions before they can effectively complete tasks. Providing this information via an API endpoint ensures agents always have access to current documentation.

**WHAT:** Create GET /api/agent/info endpoint that returns comprehensive JSON documentation including system overview, workflow expectations, task lifecycle, ID conventions, hook system, review process, API endpoints, and best practices.

**WHERE:** API controller, new AgentController

## Acceptance Criteria

- [ ] GET /api/agent/info returns comprehensive agent documentation as JSON
- [ ] Includes system overview and purpose
- [ ] Documents complete task workflow (claim → work → complete → review)
- [ ] Explains task ID prefixes (G, W, D)
- [ ] Documents hook system and AGENTS.md file
- [ ] Explains needs_review flag and review workflow
- [ ] Lists all available API endpoints with descriptions
- [ ] Includes best practices and common pitfalls
- [ ] Documents task metadata fields and their purposes
- [ ] Explains capability matching system
- [ ] Describes PubSub broadcasting expectations
- [ ] Provides example workflows for common scenarios
- [ ] Requires valid authentication (tasks:read scope)
- [ ] Returns 401 if no/invalid token
- [ ] Response is versioned (includes api_version field)

## Eating Our Own Dog Food

**Critical for Agent Onboarding:** This endpoint is the FIRST thing an AI agent should call when starting work.

**Usage Pattern:**

1. Agent receives API token
2. Call GET /api/agent/info to understand system
3. Review workflow steps, hook points, best practices
4. Check available API endpoints
5. Understand task metadata fields
6. Call GET /api/tasks/next to start working

**Why This Matters:**

- Agents learn system conventions without asking humans
- Documentation always matches current implementation
- Reduces onboarding friction for new agent instances
- Provides examples of proper API usage
- Ensures agents follow best practices from day one

**Testing Recommendation:** After implementing, use this endpoint yourself to verify the documentation is accurate and helpful. If you find yourself confused by any section, improve the response before marking task complete.

## Key Files to Read First

- [lib/kanban_web/controllers/api/agent_controller.ex](lib/kanban_web/controllers/api/agent_controller.ex) - Create new controller
- [lib/kanban_web/router.ex](lib/kanban_web/router.ex) - Add route
- [docs/WIP/UPDATE-TASKS/TASK-ID-GENERATION.md](TASK-ID-GENERATION.md) - ID prefix system
- [docs/WIP/UPDATE-TASKS/AGENTS-AND-HOOKS.md](AGENTS-AND-HOOKS.md) - Hook system documentation
- [docs/WIP/UPDATE-TASKS/NEEDS-REVIEW-FEATURE-SUMMARY.md](NEEDS-REVIEW-FEATURE-SUMMARY.md) - Review workflow
- [docs/WIP/UPDATE-TASKS/IMPROVEMENTS.md](IMPROVEMENTS.md) - System features

## Technical Notes

**Patterns to Follow:**
- Return static JSON structure (no database queries needed)
- Include version number for tracking documentation changes
- Organize by topic (workflow, hooks, API, best practices)
- Provide examples for each major concept
- Keep response comprehensive but concise
- Include links to AGENTS.md and other key resources

**Database/Schema:**
- Tables: None (read-only endpoint, no database interaction)
- Migrations needed: No

**Response Structure:**
```json
{
  "api_version": "1.0.0",
  "documentation_version": "2025-12-18",
  "system": { ... },
  "workflow": { ... },
  "task_identifiers": { ... },
  "hooks": { ... },
  "review_process": { ... },
  "api_endpoints": { ... },
  "task_metadata": { ... },
  "capabilities": { ... },
  "pubsub": { ... },
  "best_practices": { ... },
  "examples": { ... }
}
```

**Integration Points:**
- [ ] PubSub broadcasts: None (read-only)
- [ ] Phoenix Channels: None
- [ ] External APIs: None

## Verification

**Commands to Run:**

```bash
# Test endpoint
export TOKEN="kan_dev_your_token_here"

# Get agent documentation
curl http://localhost:4000/api/agent/info \
  -H "Authorization: Bearer $TOKEN" \
  | jq .

# Verify all sections present
curl http://localhost:4000/api/agent/info \
  -H "Authorization: Bearer $TOKEN" \
  | jq 'keys'

# Expected keys:
# [
#   "api_endpoints",
#   "api_version",
#   "best_practices",
#   "capabilities",
#   "documentation_version",
#   "examples",
#   "hooks",
#   "pubsub",
#   "review_process",
#   "system",
#   "task_identifiers",
#   "task_metadata",
#   "workflow"
# ]

# Test without authentication (should fail)
curl http://localhost:4000/api/agent/info

# Run tests
mix test test/kanban_web/controllers/api/agent_controller_test.exs

# Run all checks
mix precommit
```

**Manual Testing:**

1. Call endpoint with valid token
2. Verify response includes all expected sections
3. Verify workflow section explains claim → work → complete flow
4. Verify task_identifiers section explains G, W, D prefixes and 2-level hierarchy
5. Verify hooks section references AGENTS.md
6. Verify review_process section explains needs_review flag
7. Verify api_endpoints section lists all available endpoints
8. Verify examples section provides practical workflows including goal creation
9. Call endpoint without token (should return 401)
10. Call endpoint with invalid token (should return 401)

**Success Looks Like:**

- Agent can call one endpoint to understand entire system
- Documentation is comprehensive but not overwhelming
- Examples provide clear guidance for common tasks
- Response structure is easy to parse and navigate
- Agents can reference this before starting work on any task

## Data Examples

**Controller Implementation:**

```elixir
defmodule KanbanWeb.API.AgentController do
  use KanbanWeb, :controller

  plug KanbanWeb.Plugs.RequireAPIAuth
  plug KanbanWeb.Plugs.RequireScope, "tasks:read"

  @doc """
  GET /api/agent/info

  Returns comprehensive documentation for AI agents about how the system works,
  what's expected of them, and best practices.
  """
  def info(conn, _params) do
    documentation = %{
      api_version: "1.0.0",
      documentation_version: "2025-12-18",

      system: %{
        name: "Kanban AI-Optimized Task System",
        purpose: "Enable AI agents to collaborate with humans on software development tasks",
        description: "A kanban board system with rich task metadata, workflow hooks, and real-time updates designed for AI-human collaboration"
      },

      workflow: %{
        overview: "Standard task workflow: claim → work → complete → review (optional) → done",
        steps: [
          %{
            step: 1,
            action: "Get next available task",
            endpoint: "GET /api/tasks/next",
            description: "System returns the next task you're capable of completing",
            notes: "Filters by your capabilities and task dependencies automatically"
          },
          %{
            step: 2,
            action: "Claim the task",
            endpoint: "POST /api/tasks/:id/claim",
            description: "Atomically claim the task to prevent other agents from working on it",
            notes: "Claim expires after 60 minutes of inactivity. Use unclaim if you can't complete it."
          },
          %{
            step: 3,
            action: "Read task details",
            endpoint: "GET /api/tasks/:id",
            description: "Get full task details including key files, verification steps, etc.",
            notes: "Use this to understand what needs to be done and how to verify completion"
          },
          %{
            step: 4,
            action: "Execute workflow hooks",
            hook: "after_claim, before_column_enter[In Progress], etc.",
            description: "Run commands defined in AGENTS.md file at workflow transition points",
            notes: "See hooks section below for complete documentation"
          },
          %{
            step: 5,
            action: "Complete the work",
            description: "Implement the feature, fix the bug, write the documentation, etc.",
            notes: "Follow patterns in key_files, run verification_steps, avoid pitfalls"
          },
          %{
            step: 6,
            action: "Mark task complete",
            endpoint: "POST /api/tasks/:id/complete",
            description: "Submit completion with summary of work done",
            notes: "Include actual complexity, files changed, time spent, challenges encountered"
          },
          %{
            step: 7,
            action: "Review (if needed)",
            description: "If needs_review=true, task enters review queue for human approval",
            notes: "If needs_review=false, task moves directly to done. Review hooks still execute."
          }
        ],
        claim_timeout: "60 minutes",
        unclaim_endpoint: "POST /api/tasks/:id/unclaim",
        unclaim_reason_required: true
      },

      task_identifiers: %{
        description: "All tasks have human-readable prefixed identifiers",
        prefixes: %{
          G: "Goal - Large initiatives (25+ hours, multiple tasks)",
          W: "Work - Individual work items (1-3 hours)",
          D: "Defect - Bug fixes and corrections"
        },
        task_types: %{
          goal: "Large initiatives that contain multiple tasks",
          work: "New functionality or enhancements",
          defect: "Bug fixes and corrections"
        },
        examples: [
          "G1: Implement AI-Optimized Task System",
          "W42: Add task completion endpoint",
          "D7: Fix race condition in task claiming"
        ],
        hierarchy: "2-level: Goal (G1) → Tasks (W1, W2, W3, D1, D2)",
        reference: "See TASK-ID-GENERATION.md for complete documentation"
      },

      hooks: %{
        description: "Execute custom commands at workflow transition points",
        config_file: "AGENTS.md in repository root",
        hook_points: [
          "before_claim - Runs before claiming a task",
          "after_claim - Runs after successfully claiming a task",
          "before_column_enter[Column Name] - Runs when entering a column",
          "after_column_enter[Column Name] - Runs after entering a column",
          "before_column_exit[Column Name] - Runs before exiting a column",
          "after_column_exit[Column Name] - Runs after exiting a column",
          "before_complete - Runs before marking task complete",
          "after_complete - Runs after task marked complete",
          "before_unclaim - Runs before unclaiming a task",
          "after_unclaim - Runs after unclaiming a task"
        ],
        blocking_hooks: [
          "before_claim",
          "before_complete",
          "before_column_enter",
          "before_column_exit"
        ],
        non_blocking_hooks: [
          "after_claim",
          "after_complete",
          "after_column_enter",
          "after_column_exit"
        ],
        environment_variables: [
          "TASK_ID - Task database ID",
          "TASK_TITLE - Task title",
          "TASK_DESCRIPTION - Task description",
          "TASK_STATUS - Current task status",
          "TASK_COMPLEXITY - Task complexity (small/medium/large)",
          "TASK_PRIORITY - Task priority (0-highest)",
          "TASK_NEEDS_REVIEW - Whether task requires human review (true/false)",
          "BOARD_ID - Board database ID",
          "BOARD_NAME - Board name",
          "COLUMN_ID - Column database ID",
          "COLUMN_NAME - Current column name",
          "PREV_COLUMN_NAME - Previous column name (for moves)",
          "AGENT_NAME - Your agent name",
          "AGENT_CAPABILITIES - Your capabilities (comma-separated)",
          "API_TOKEN - Your API token",
          "HOOK_NAME - Current hook name",
          "HOOK_TIMEOUT - Hook timeout in seconds",
          "UNCLAIM_REASON - Reason for unclaim (unclaim hooks only)"
        ],
        reference: "See AGENTS-AND-HOOKS.md for complete hook system documentation",
        example_agents_md: "See examples section below"
      },

      review_process: %{
        description: "Optional human review based on needs_review flag",
        needs_review_field: "Boolean field on task (default: false)",
        workflow_when_true: [
          "Task moves to Review column after completion",
          "Human reviews the work and sets review_status",
          "Review hooks execute (quality checks)",
          "Task waits for human approval",
          "If approved → moves to Done",
          "If changes_requested → returns to In Progress with review_notes"
        ],
        workflow_when_false: [
          "Task skips Review column",
          "Moves directly to Done after completion",
          "Review hooks still execute (automated quality checks)",
          "No human intervention required"
        ],
        use_cases_needs_review_true: [
          "Security-related changes",
          "Database schema migrations",
          "API contract changes",
          "Production configuration changes",
          "Financial/payment processing logic"
        ],
        use_cases_needs_review_false: [
          "Documentation updates",
          "Automated dependency updates",
          "Minor bug fixes in non-critical code",
          "Test additions",
          "Code formatting changes"
        ],
        review_statuses: [
          "pending - Awaiting human review",
          "approved - Human approved, task can move to done",
          "changes_requested - Human requested changes, check review_notes",
          "rejected - Human rejected, task should be unclaimed or closed"
        ],
        get_review_status: "GET /api/tasks/:id/review",
        reference: "See NEEDS-REVIEW-FEATURE-SUMMARY.md for complete documentation"
      },

      api_endpoints: %{
        authentication: %{
          method: "Bearer token",
          header: "Authorization: Bearer YOUR_TOKEN",
          scopes: ["tasks:read", "tasks:write"],
          description: "All API endpoints require authentication"
        },
        endpoints: [
          %{
            method: "GET",
            path: "/api/agent/info",
            description: "Get this documentation",
            scope: "tasks:read"
          },
          %{
            method: "GET",
            path: "/api/tasks/next",
            description: "Get next available task matching your capabilities",
            scope: "tasks:read",
            query_params: ["?board_id=X - Filter by board"]
          },
          %{
            method: "POST",
            path: "/api/tasks/:id/claim",
            description: "Atomically claim a task",
            scope: "tasks:write",
            returns: "Task with claimed_at and claim_expires_at timestamps"
          },
          %{
            method: "POST",
            path: "/api/tasks/:id/unclaim",
            description: "Release a claimed task",
            scope: "tasks:write",
            body: %{reason: "Why you're unclaiming (required)"}
          },
          %{
            method: "GET",
            path: "/api/tasks/:id",
            description: "Get task details",
            scope: "tasks:read"
          },
          %{
            method: "GET",
            path: "/api/tasks/:id/tree",
            description: "Get hierarchical tree (goal → tasks)",
            scope: "tasks:read"
          },
          %{
            method: "GET",
            path: "/api/tasks/:id/validate",
            description: "Validate task readiness (dry-run before claim)",
            scope: "tasks:read",
            returns: "Readiness status and any blocking issues"
          },
          %{
            method: "POST",
            path: "/api/tasks/:id/complete",
            description: "Mark task complete with summary",
            scope: "tasks:write",
            body: %{
              completion_summary: "Description of work done",
              actual_complexity: "small | medium | large",
              actual_files_changed: "Number of files modified",
              time_spent_minutes: "Time spent in minutes"
            }
          },
          %{
            method: "GET",
            path: "/api/tasks/:id/review",
            description: "Get review status and notes",
            scope: "tasks:read"
          },
          %{
            method: "POST",
            path: "/api/tasks",
            description: "Create new task",
            scope: "tasks:write",
            body: "See task_metadata section for all available fields"
          },
          %{
            method: "POST",
            path: "/api/tasks/batch",
            description: "Create multiple tasks with temp IDs for dependencies",
            scope: "tasks:write",
            body: %{
              tasks: [
                %{temp_id: "t1", title: "Task 1", dependencies: []},
                %{temp_id: "t2", title: "Task 2", dependencies: ["t1"]}
              ]
            }
          },
          %{
            method: "PATCH",
            path: "/api/tasks/:id",
            description: "Update task fields",
            scope: "tasks:write"
          }
        ]
      },

      task_metadata: %{
        description: "Rich task metadata fields available on all tasks",
        core_fields: %{
          id: "Database ID (integer)",
          identifier: "Human-readable ID (G1, W42, D7)",
          title: "Task title (required)",
          description: "Detailed task description",
          type: "work | defect (for tasks only, not goals)",
          task_type: "goal | work | defect (hierarchy level)",
          parent_id: "Parent task ID (for tasks in goals)",
          complexity: "small | medium | large",
          estimated_files: "1-2 | 3-5 | 5+",
          priority: "0 (highest) to N (lowest)",
          status: "open | in_progress | completed | blocked",
          position: "Position in column (for ordering)"
        },
        context_fields: %{
          why: "Problem being solved",
          what: "Specific feature/change being implemented",
          where_context: "UI location or code area affected",
          patterns_to_follow: "Existing patterns to use",
          database_changes: "Migration/schema notes"
        },
        technology_fields: %{
          technology_requirements: "Required technologies/integrations",
          key_files: "Important files to read/modify",
          verification_steps: "Commands/steps to verify completion"
        },
        observability_fields: %{
          telemetry_event: "Telemetry event name",
          metrics_to_track: "What to measure",
          logging_requirements: "What to log"
        },
        error_handling_fields: %{
          error_user_message: "What user sees on error",
          error_on_failure: "What happens on failure",
          validation_rules: "Input validation needed"
        },
        guidance_fields: %{
          pitfalls: "Common mistakes to avoid",
          out_of_scope: "What NOT to do"
        },
        lifecycle_fields: %{
          created_by_id: "User who created task",
          created_by_agent: "AI agent name if AI-created",
          completed_at: "When task was completed",
          completed_by_id: "User who completed task",
          completed_by_agent: "AI agent name if AI-completed",
          completion_summary: "Summary of work done",
          claimed_at: "When task was claimed",
          claim_expires_at: "When claim expires (60 min from claim)",
          actual_complexity: "Actual complexity experienced",
          actual_files_changed: "Actual files modified",
          time_spent_minutes: "Actual time spent"
        },
        dependency_fields: %{
          dependencies: "Array of task IDs this task depends on",
          blocked_by: "Tasks blocking this one (computed)",
          blocks: "Tasks this one blocks (computed)"
        },
        review_fields: %{
          needs_review: "Whether task requires human review (boolean)",
          review_status: "pending | approved | changes_requested | rejected",
          review_notes: "Human feedback on completed work",
          reviewed_by_id: "User who reviewed",
          reviewed_at: "When reviewed"
        },
        capability_fields: %{
          required_capabilities: "Array of capabilities needed to claim task",
          examples: ["code_generation", "testing", "documentation", "database_design"]
        }
      },

      capabilities: %{
        description: "Tasks specify required capabilities, agents have capability lists",
        matching: "Task only claimable if agent has ALL required capabilities",
        common_capabilities: [
          "code_generation - Writing new code",
          "testing - Writing/running tests",
          "documentation - Writing docs",
          "refactoring - Code refactoring",
          "debugging - Bug investigation",
          "database_design - Schema/migration design",
          "api_design - API endpoint design",
          "ui_design - User interface design",
          "security_analysis - Security review",
          "performance_optimization - Performance tuning"
        ],
        your_capabilities: "Check your API token's capabilities field",
        empty_required_capabilities: "If task has empty required_capabilities, any agent can claim it"
      },

      pubsub: %{
        description: "Real-time updates broadcast when tasks change",
        expectation: "When you update a task via API, system broadcasts changes to all connected clients",
        topics: [
          "tasks:board:{board_id} - All task changes for a board",
          "tasks:task:{task_id} - Specific task changes"
        ],
        events: [
          "task_created - New task created",
          "task_claimed - Task claimed by agent",
          "task_unclaimed - Task unclaimed",
          "task_moved - Task moved between columns",
          "task_completed - Task marked complete",
          "task_reviewed - Human reviewed task",
          "task_status_changed - Task status changed",
          "task_updated - Task fields updated",
          "task_deleted - Task deleted"
        ],
        agent_responsibility: "You don't need to broadcast - the API endpoints handle this automatically",
        reference: "See PUBSUB-REALTIME-UPDATES.md for complete documentation"
      },

      best_practices: %{
        before_starting: [
          "Read this documentation endpoint first",
          "Review AGENTS.md file in repository root",
          "Understand the task ID prefix system (E, F, W, D)",
          "Check your capabilities match task requirements",
          "Use validate endpoint before claiming"
        ],
        when_claiming: [
          "Always use GET /api/tasks/next instead of selecting tasks yourself",
          "Claim expires in 60 minutes - complete work or unclaim before timeout",
          "Execute after_claim hook if defined in AGENTS.md",
          "Move task to 'In Progress' column if not automatic"
        ],
        during_work: [
          "Read all key_files listed in task metadata",
          "Follow patterns_to_follow guidance",
          "Avoid pitfalls listed in task",
          "Don't implement out_of_scope items",
          "Run verification_steps as you work",
          "Execute column transition hooks (before/after enter/exit)"
        ],
        before_completing: [
          "Run all verification_steps from task metadata",
          "Execute before_complete hook if defined",
          "Ensure all tests pass",
          "Check code quality (linting, formatting)",
          "Verify no regressions introduced"
        ],
        when_completing: [
          "Provide accurate completion_summary",
          "Report actual_complexity (may differ from estimated)",
          "Count actual_files_changed",
          "Estimate time_spent_minutes",
          "List follow-up tasks discovered in completion_summary.follow_up_tasks",
          "Create new tasks via POST /api/tasks for each follow-up item",
          "Link follow-up tasks to current task via dependencies field",
          "Execute after_complete hook (usually git commit/push)"
        ],
        if_blocked: [
          "Don't wait on tasks - unclaim immediately if blocked",
          "Provide clear unclaim reason for analytics",
          "Execute before_unclaim and after_unclaim hooks",
          "System will make task available to other agents",
          "Check dependencies - may need to work on blocking tasks first"
        ],
        review_workflow: [
          "Check needs_review flag before completing",
          "If true, expect human review before task moves to done",
          "Review hooks execute even if needs_review=false",
          "If changes_requested, read review_notes carefully",
          "Address all feedback before re-completing"
        ],
        common_pitfalls: [
          "Don't select your own tasks - use GET /api/tasks/next",
          "Don't claim tasks beyond your capabilities",
          "Don't skip verification steps",
          "Don't ignore hook execution failures",
          "Don't leave tasks claimed if you can't complete them",
          "Don't implement features marked as out_of_scope",
          "Don't forget to execute AGENTS.md hooks",
          "Don't assume needs_review=false means skip quality checks",
          "Don't just document follow-up tasks - create them via POST /api/tasks"
        ],
        efficiency_tips: [
          "Use batch endpoint when creating multiple related tasks",
          "Use tree endpoint to understand full context (goal → tasks)",
          "Use validate endpoint before claiming to avoid wasted claims",
          "Read task dependencies to understand blocking relationships",
          "Check review_status regularly when needs_review=true"
        ]
      },

      examples: %{
        example_1_simple_task_workflow: %{
          description: "Complete a documentation task (no review needed)",
          steps: [
            %{
              step: "Get next task",
              request: "GET /api/tasks/next",
              response: %{
                id: 42,
                identifier: "W42",
                title: "Update API documentation",
                complexity: "small",
                needs_review: false,
                required_capabilities: ["documentation"]
              }
            },
            %{
              step: "Validate task",
              request: "GET /api/tasks/42/validate",
              response: %{can_claim: true, reasons: []}
            },
            %{
              step: "Claim task",
              request: "POST /api/tasks/42/claim",
              response: %{
                claimed_at: "2025-12-18T10:00:00Z",
                claim_expires_at: "2025-12-18T11:00:00Z"
              }
            },
            %{
              step: "Execute after_claim hook",
              hook: "Run commands from AGENTS.md after_claim section",
              example: "git checkout -b task-42-update-api-documentation"
            },
            %{
              step: "Do the work",
              description: "Update API documentation files"
            },
            %{
              step: "Execute before_complete hook",
              hook: "Run commands from AGENTS.md before_complete section",
              example: "mix precommit (runs tests, linters, etc.)"
            },
            %{
              step: "Complete task",
              request: "POST /api/tasks/42/complete",
              body: %{
                completion_summary: "Updated API documentation for new endpoints",
                actual_complexity: "small",
                actual_files_changed: 3,
                time_spent_minutes: 25
              }
            },
            %{
              step: "Execute after_complete hook",
              hook: "Run commands from AGENTS.md after_complete section",
              example: "git commit && git push"
            },
            %{
              step: "Task moves to Done",
              description: "Since needs_review=false, task skips review and goes directly to Done"
            }
          ]
        },

        example_2_task_requiring_review: %{
          description: "Complete a security task (requires human review)",
          steps: [
            %{
              step: "Get and claim task",
              request: "GET /api/tasks/next → POST /api/tasks/43/claim",
              response: %{
                id: 43,
                identifier: "W43",
                title: "Implement OAuth2 authentication",
                complexity: "large",
                needs_review: true,
                required_capabilities: ["code_generation", "security_analysis"]
              }
            },
            %{
              step: "Do the work",
              description: "Implement OAuth2 authentication"
            },
            %{
              step: "Complete task",
              request: "POST /api/tasks/43/complete",
              body: %{
                completion_summary: "Implemented OAuth2 with PKCE flow",
                actual_complexity: "large",
                actual_files_changed: 8,
                time_spent_minutes: 180
              }
            },
            %{
              step: "Task enters Review",
              description: "Since needs_review=true, task moves to Review column and waits for human"
            },
            %{
              step: "Check review status",
              request: "GET /api/tasks/43/review",
              response: %{
                review_status: "pending",
                review_notes: nil,
                reviewed_by_id: nil
              }
            },
            %{
              step: "Wait for human review",
              description: "Poll review endpoint or wait for PubSub notification"
            },
            %{
              step: "Review completed",
              pubsub_event: "task_reviewed",
              review_status: "approved",
              description: "Human approved the security implementation"
            },
            %{
              step: "Task moves to Done",
              description: "After approval, task moves to Done column"
            }
          ]
        },

        example_3_unclaim_when_blocked: %{
          description: "Unclaim a task when you discover missing dependencies",
          steps: [
            %{
              step: "Claim task",
              request: "POST /api/tasks/44/claim",
              response: %{
                id: 44,
                identifier: "W44",
                title: "Add user preferences endpoint",
                dependencies: [40, 41]
              }
            },
            %{
              step: "Check dependencies",
              request: "GET /api/tasks/40, GET /api/tasks/41",
              response: "Both dependencies are still in 'open' status, not completed"
            },
            %{
              step: "Unclaim task",
              request: "POST /api/tasks/44/unclaim",
              body: %{
                reason: "Dependencies (W40, W41) not yet completed - user preferences table doesn't exist"
              }
            },
            %{
              step: "Task released",
              description: "Task becomes available for other agents or retry later after dependencies complete"
            }
          ]
        },

        example_4_create_goal_structure: %{
          description: "Create a goal with tasks using batch endpoint",
          steps: [
            %{
              step: "Create goal and tasks in one request",
              request: "POST /api/tasks/batch",
              body: %{
                tasks: [
                  %{
                    temp_id: "goal1",
                    title: "Implement notification system",
                    task_type: "goal",
                    complexity: "large",
                    dependencies: []
                  },
                  %{
                    temp_id: "task1",
                    title: "Design notification schema",
                    type: "work",
                    task_type: "work",
                    parent_id: "goal1",
                    complexity: "small",
                    dependencies: []
                  },
                  %{
                    temp_id: "task2",
                    title: "Implement email sender",
                    type: "work",
                    task_type: "work",
                    parent_id: "goal1",
                    complexity: "medium",
                    dependencies: ["task1"]
                  },
                  %{
                    temp_id: "task3",
                    title: "Fix notification race condition",
                    type: "defect",
                    task_type: "defect",
                    parent_id: "goal1",
                    complexity: "small",
                    dependencies: ["task2"]
                  }
                ]
              },
              response: %{
                data: [
                  %{id: 100, identifier: "G1", temp_id: "goal1"},
                  %{id: 102, identifier: "W45", temp_id: "task1"},
                  %{id: 103, identifier: "W46", temp_id: "task2"},
                  %{id: 104, identifier: "D1", temp_id: "task3"}
                ]
              }
            },
            %{
              step: "View hierarchy",
              request: "GET /api/tasks/100/tree",
              description: "Get complete goal structure with all tasks"
            }
          ]
        },

        example_agents_md_file: %{
          description: "Example AGENTS.md file defining hook behaviors",
          content: """
# Agent Configuration

This file defines how AI agents should behave when working on tasks in this project.

## Agent: Claude Sonnet 4.5

### Capabilities
- code_generation
- testing
- documentation
- refactoring
- security_analysis

### Hook Implementations

#### after_claim
```bash
# Create feature branch for this task
TASK_ID="$TASK_ID"
BRANCH_NAME="task-${TASK_ID}-$(echo $TASK_TITLE | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
git checkout -b "$BRANCH_NAME" origin/main
echo "Created branch: $BRANCH_NAME"
```

#### before_column_enter[In Progress]
```bash
# Rebase on main before starting work
git fetch origin main
git rebase origin/main
```

#### before_complete
```bash
# Run all quality checks before completion
mix format --check-formatted || exit 1
mix credo --strict || exit 1
mix test || exit 1
mix dialyzer || exit 1
```

#### after_complete
```bash
# Commit and push changes
git add .
git commit -m "Complete task $TASK_ID: $TASK_TITLE

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"

git push origin HEAD
```

#### before_column_enter[Review]
```bash
# Always run automated quality checks
mix test || exit 1
mix credo --strict || exit 1

# Only request human review if needed
if [ "$TASK_NEEDS_REVIEW" = "true" ]; then
  echo "🔍 Requesting human review for task $TASK_ID"
else
  echo "✅ Task $TASK_ID auto-approved (no review required)"
fi
```
          """
        }
      }
    }

    json(conn, documentation)
  end
end
```

**Router Addition:**

```elixir
# lib/kanban_web/router.ex

scope "/api", KanbanWeb.API do
  pipe_through :api
  pipe_through :api_auth

  # Agent information endpoint
  get "/agent/info", AgentController, :info

  # ... existing routes
end
```

**Test Implementation:**

```elixir
defmodule KanbanWeb.API.AgentControllerTest do
  use KanbanWeb.ConnCase

  describe "GET /api/agent/info" do
    test "returns comprehensive agent documentation", %{conn: conn} do
      token = insert(:api_token, scopes: ["tasks:read"])

      conn = conn
        |> put_req_header("authorization", "Bearer #{token.token}")
        |> get("/api/agent/info")

      assert %{
        "api_version" => "1.0.0",
        "documentation_version" => _,
        "system" => system,
        "workflow" => workflow,
        "task_identifiers" => task_identifiers,
        "hooks" => hooks,
        "review_process" => review_process,
        "api_endpoints" => api_endpoints,
        "task_metadata" => task_metadata,
        "capabilities" => capabilities,
        "pubsub" => pubsub,
        "best_practices" => best_practices,
        "examples" => examples
      } = json_response(conn, 200)

      # Verify workflow section
      assert workflow["overview"] =~ "claim → work → complete"
      assert workflow["claim_timeout"] == "60 minutes"
      assert length(workflow["steps"]) == 7

      # Verify task identifiers section
      assert task_identifiers["prefixes"]["G"] =~ "Goal"
      assert task_identifiers["prefixes"]["W"] =~ "Work"
      assert task_identifiers["prefixes"]["D"] =~ "Defect"
      assert task_identifiers["hierarchy"] =~ "2-level"

      # Verify hooks section
      assert hooks["config_file"] == "AGENTS.md in repository root"
      assert length(hooks["hook_points"]) > 0
      assert length(hooks["environment_variables"]) > 0

      # Verify review process section
      assert review_process["needs_review_field"] =~ "Boolean"
      assert length(review_process["workflow_when_true"]) > 0
      assert length(review_process["workflow_when_false"]) > 0

      # Verify API endpoints section
      assert api_endpoints["authentication"]["method"] == "Bearer token"
      assert length(api_endpoints["endpoints"]) > 0

      # Verify examples section
      assert examples["example_1_simple_task_workflow"]
      assert examples["example_2_task_requiring_review"]
      assert examples["example_3_unclaim_when_blocked"]
      assert examples["example_4_create_goal_structure"]
      assert examples["example_agents_md_file"]
    end

    test "requires authentication", %{conn: conn} do
      conn = get(conn, "/api/agent/info")
      assert json_response(conn, 401)
    end

    test "requires tasks:read scope", %{conn: conn} do
      token = insert(:api_token, scopes: ["tasks:write"])

      conn = conn
        |> put_req_header("authorization", "Bearer #{token.token}")
        |> get("/api/agent/info")

      assert json_response(conn, 403)
    end
  end
end
```

## Observability

**Telemetry:**
```elixir
:telemetry.execute(
  [:kanban, :api, :agent_info, :accessed],
  %{duration_ms: 5},
  %{
    agent_name: "claude-sonnet-4.5",
    api_token_id: 123
  }
)
```

**Metrics:**
- Counter: Agent info endpoint accesses by agent
- Histogram: Response time

**Logging:**
```
[info] Agent documentation accessed: agent=claude-sonnet-4.5 token_id=123
```

## Benefits

### For AI Agents

1. **Single Source of Truth**: One endpoint provides all necessary documentation
2. **Always Current**: Documentation served from live system, never outdated
3. **Comprehensive**: Covers workflow, hooks, review, API, best practices
4. **Practical Examples**: Real-world scenarios with request/response samples
5. **Self-Service**: No need to ask humans how the system works

### For Humans

1. **Onboarding**: New agents can learn system autonomously
2. **Consistency**: All agents receive same information
3. **Versioning**: Documentation version tracked for debugging
4. **Maintenance**: Update in one place, all agents benefit

### For System

1. **Reduced Support**: Fewer questions about system operation
2. **Better Compliance**: Agents follow documented best practices
3. **Auditability**: Can verify what documentation agent received
4. **Evolvability**: Easy to add new sections as system grows

## Documentation Updates

When system changes, update the info endpoint response to reflect:

- New API endpoints
- New hook points
- New task metadata fields
- Changed workflow requirements
- New best practices
- Updated examples

Increment `documentation_version` field when making updates.

## Future Enhancements (Out of Scope)

1. **Localization**: Support multiple languages
2. **Agent-Specific Docs**: Customize based on agent capabilities
3. **Interactive Tutorials**: Step-by-step guided workflows
4. **Version History**: Track documentation changes over time
5. **Schema Validation**: OpenAPI/JSON Schema for all endpoints
6. **Code Samples**: Language-specific examples (Python, JavaScript, etc.)
7. **Video Tutorials**: Recorded walkthroughs
8. **FAQ Section**: Common questions and answers

## References

- **Related Tasks:** Task 06 (API Authentication), Task 07 (CRUD API), Task 08 (Claim/Unclaim)
- **Documentation:** All implementation summaries and feature docs in UPDATE-TASKS/
- **Hook System:** [AGENTS-AND-HOOKS.md](AGENTS-AND-HOOKS.md)
- **ID System:** [TASK-ID-GENERATION.md](TASK-ID-GENERATION.md)
- **Review System:** [NEEDS-REVIEW-FEATURE-SUMMARY.md](NEEDS-REVIEW-FEATURE-SUMMARY.md)
- **PubSub:** [PUBSUB-REALTIME-UPDATES.md](PUBSUB-REALTIME-UPDATES.md)

## Summary

The GET /api/agent/info endpoint provides comprehensive, versioned documentation to AI agents about how the Stride system works, what's expected of them, and how to successfully complete tasks. This single endpoint eliminates the need for agents to hunt through multiple documentation files or ask humans basic questions, ensuring all agents receive consistent, up-to-date information about system operation, workflows, hooks, review processes, and best practices.
