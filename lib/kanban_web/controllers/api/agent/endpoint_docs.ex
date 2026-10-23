defmodule KanbanWeb.API.Agent.EndpointDocs do
  @moduledoc """
  The `api_reference.endpoints` catalogue of the agent onboarding payload —
  the discovery, management and creation endpoint lists — extracted from
  `KanbanWeb.API.AgentJSON` to keep that module under the size limit, in the
  same way as `SchemaDoc`, `SetupDocs` and `MultiAgentInstructions` (W1442).
  Pure data.

  Agents discover the API from this list, so an endpoint missing here is an
  endpoint agents will not use.
  """

  @docs_base_url "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main"

  # What PATCH /api/tasks/:id/complete rejects without (D389): the two blocking
  # hook results (TaskActions), the four fields the completion changeset
  # requires (AgentWorkflow), and explorer_result and reviewer_result, which
  # strict mode — the production default — rejects when absent.
  @complete_required_parameters [
    "after_doing_result",
    "before_review_result",
    "completion_summary",
    "actual_complexity",
    "actual_files_changed",
    "time_spent_minutes",
    "explorer_result",
    "reviewer_result"
  ]

  @doc """
  The body parameters `PATCH /api/tasks/:id/complete` needs. `AgentJSON`
  publishes the same list, so the two catalogues cannot disagree.
  """
  def complete_required_parameters, do: @complete_required_parameters

  @doc """
  The body parameters `PATCH /api/tasks/:id/mark_reviewed` needs: the blocking
  `after_review` hook result.
  """
  def mark_reviewed_required_parameters, do: ["after_review_result"]

  @doc "The `api_reference.endpoints` section of the onboarding payload."
  def endpoints do
    %{
      discovery: [
        %{
          method: "GET",
          path: "/api/boards",
          description:
            "List the boards this token can use: a board token's one board, or the boards of a workspace token's workspace its user can modify. Needs no X-Stride-Board header",
          auth_required: true,
          documentation_url: "#{@docs_base_url}/docs/api/get_boards.md"
        },
        %{
          method: "GET",
          path: "/api/agent/onboarding",
          description:
            "This onboarding payload: setup files, hooks, the workflow and the API schema. Needs no token",
          auth_required: false,
          documentation_url: "#{@docs_base_url}/docs/api/get_agent_onboarding.md"
        },
        %{
          method: "GET",
          path: "/api/openapi.json",
          description:
            "Machine-readable OpenAPI 3.1 description of every /api route, for client generation and tool schemas. Needs no token",
          auth_required: false,
          documentation_url: "#{@docs_base_url}/docs/api/get_openapi_json.md"
        },
        %{
          method: "GET",
          path: "/api/tasks/next",
          description: "Get next available task",
          auth_required: true,
          documentation_url: "#{@docs_base_url}/docs/api/get_tasks_next.md"
        },
        %{
          method: "GET",
          path: "/api/tasks",
          description:
            "List tasks; optional filters (column_id, status, type, priority, assigned_to_id, parent, updated_since, label — a label name) and cursor pagination (limit, cursor -> meta.next_cursor). For incremental sync with updated_since, read the Incremental sync caveats in the docs first: full view only, bound from server-stamped updated_at with an overlap, upsert by id",
          auth_required: true,
          documentation_url: "#{@docs_base_url}/docs/api/get_tasks.md"
        },
        %{
          method: "GET",
          path: "/api/tasks/:id",
          description: "Get specific task",
          auth_required: true,
          documentation_url: "#{@docs_base_url}/docs/api/get_tasks_id.md"
        },
        %{
          method: "GET",
          path: "/api/tasks/:id/tree",
          description: "Get task tree (goals with children)",
          auth_required: true,
          documentation_url: "#{@docs_base_url}/docs/api/get_tasks_id_tree.md"
        },
        %{
          method: "GET",
          path: "/api/tasks/:id/dependencies",
          description: "List the tasks this task depends on",
          auth_required: true,
          documentation_url: "#{@docs_base_url}/docs/api/get_tasks_id_dependencies.md"
        },
        %{
          method: "GET",
          path: "/api/tasks/:id/dependents",
          description: "List the tasks that depend on this task",
          auth_required: true,
          documentation_url: "#{@docs_base_url}/docs/api/get_tasks_id_dependents.md"
        },
        %{
          method: "GET",
          path: "/api/tasks/:id/comments",
          description:
            "List a task's comments, oldest first: the most recent limit (default 50, max 200), with meta.has_more when older ones exist. GET /api/tasks/:id carries comment_count",
          auth_required: true,
          documentation_url: "#{@docs_base_url}/docs/api/get_tasks_id_comments.md"
        },
        %{
          method: "GET",
          path: "/api/tasks/:id/after_goal_status",
          description:
            "Read-only. Whether completing task :id armed its goal's after_goal hook, with the GOAL_* environment variables for running the ## after_goal section locally",
          auth_required: true,
          documentation_url: "#{@docs_base_url}/docs/api/get_tasks_id_after_goal_status.md"
        }
      ],
      management: [
        %{
          method: "POST",
          path: "/api/tasks/claim",
          description: "Claim a task - REQUIRES before_doing_result parameter",
          required_parameters: ["before_doing_result"],
          hook_validation_required: true,
          returns_hooks: ["before_doing"],
          auth_required: true,
          documentation_url: "#{@docs_base_url}/docs/api/post_tasks_claim.md"
        },
        %{
          method: "POST",
          path: "/api/tasks/:id/unclaim",
          description: "Unclaim a task",
          returns_hooks: [],
          auth_required: true,
          documentation_url: "#{@docs_base_url}/docs/api/post_tasks_id_unclaim.md"
        },
        %{
          method: "PATCH",
          path: "/api/tasks/:id/complete",
          description:
            "Complete a task - REQUIRES after_doing_result and before_review_result (both hooks exit 0), completion_summary, actual_complexity, actual_files_changed and time_spent_minutes, plus explorer_result and reviewer_result (rejected when absent in strict mode, the production default; a dispatched reviewer_result needs the full structured block in every mode — see api_schema.reviewer_result_format). changed_files in the body is silently ignored; use PUT /api/tasks/:id/changed_files instead.",
          required_parameters: @complete_required_parameters,
          hook_validation_required: true,
          returns_hooks: [
            "after_doing",
            "before_review",
            "after_review (conditional)",
            "after_goal (only when needs_review=false and the task was the last open child of a goal)"
          ],
          auth_required: true,
          documentation_url: "#{@docs_base_url}/docs/api/patch_tasks_id_complete.md"
        },
        %{
          method: "PUT",
          path: "/api/tasks/:id/changed_files",
          description:
            "Upload the per-file diff snapshot — sole writer for tasks.changed_files. Encoding defined in docs/diff-contract.md.",
          required_parameters: ["changed_files"],
          hook_validation_required: false,
          returns_hooks: [],
          auth_required: true,
          documentation_url: "#{@docs_base_url}/docs/api/put_tasks_id_changed_files.md"
        },
        %{
          method: "PATCH",
          path: "/api/tasks/:id/mark_reviewed",
          description:
            "Finalize review - REQUIRES after_review_result, the result of running the after_review hook",
          required_parameters: ["after_review_result"],
          hook_validation_required: true,
          returns_hooks: [
            "after_review (if approved)",
            "after_goal (if approved and the task was the last open child of a goal)"
          ],
          auth_required: true,
          documentation_url: "#{@docs_base_url}/docs/api/patch_tasks_id_mark_reviewed.md"
        },
        %{
          method: "PATCH",
          path: "/api/tasks/:id/mark_done",
          description:
            "Move a task from the Review column straight to Done without a review. Returns 422 when the task is not in Review. Never arms or delivers after_goal",
          returns_hooks: [],
          auth_required: true,
          documentation_url: "#{@docs_base_url}/docs/api/patch_tasks_id_mark_done.md"
        },
        %{
          method: "PATCH",
          path: "/api/tasks/:id/after_goal",
          description:
            "Report the result of a goal's after_goal hook, where :id is the goal. Body: exit_code, output, duration_ms. Exit code 0 moves the goal to Done; any other exit code is recorded and the goal stays where it is, so you can fix the problem and report again",
          required_parameters: ["exit_code", "output", "duration_ms"],
          returns_hooks: [],
          auth_required: true,
          documentation_url: "#{@docs_base_url}/docs/api/patch_tasks_id_after_goal.md"
        },
        %{
          method: "POST",
          path: "/api/tasks/:id/comments",
          description:
            "Add a comment to a task. Body: content (required, 1-10,000 characters) and optional agent_name. The author is the token's user; the agent name is resolved token agent_model, then agent_name, then the token's last agent name. Mention a board member with an @[Name](user:ID) token; mentions of non-members stay plain text. Every board member can read comments, so never put a secret in one",
          required_parameters: ["content"],
          returns_hooks: [],
          auth_required: true,
          documentation_url: "#{@docs_base_url}/docs/api/post_tasks_id_comments.md"
        },
        %{
          method: "POST",
          path: "/api/mcp",
          description:
            "Model Context Protocol server (JSON-RPC 2.0 over Streamable HTTP). Its claim and complete tools run the same validation as the REST endpoints",
          auth_required: true,
          documentation_url: "#{@docs_base_url}/docs/MCP.md"
        },
        %{
          method: "GET",
          path: "/api/mcp",
          description: "Not supported: returns 405. Use POST /api/mcp",
          auth_required: true,
          documentation_url: "#{@docs_base_url}/docs/MCP.md"
        },
        %{
          method: "DELETE",
          path: "/api/mcp",
          description: "Not supported: returns 405. Use POST /api/mcp",
          auth_required: true,
          documentation_url: "#{@docs_base_url}/docs/MCP.md"
        }
      ],
      creation: [
        %{
          method: "POST",
          path: "/api/tasks",
          description:
            "Create task, or goal with nested work and defect tasks (a goal cannot contain a goal). A work or defect task whose column is at its WIP limit returns 422; goals are never WIP-checked",
          auth_required: true,
          documentation_url: "#{@docs_base_url}/docs/api/post_tasks.md"
        },
        %{
          method: "PATCH",
          path: "/api/tasks/:id",
          description:
            "Update a task's fields (title, description, labels, behaviour_test_matrix and so on). Send them under a task root key",
          auth_required: true,
          documentation_url: "#{@docs_base_url}/docs/api/patch_tasks_id.md"
        },
        %{
          method: "PUT",
          path: "/api/tasks/:id",
          description: "Same action as PATCH /api/tasks/:id",
          auth_required: true,
          documentation_url: "#{@docs_base_url}/docs/api/patch_tasks_id.md"
        },
        %{
          method: "POST",
          path: "/api/tasks/batch",
          description:
            "Create multiple goals with nested tasks in one request (efficient for project planning)",
          auth_required: true,
          documentation_url: "#{@docs_base_url}/docs/api/post_tasks_batch.md"
        }
      ]
    }
  end
end
