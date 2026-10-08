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

  @doc "The `api_reference.endpoints` section of the onboarding payload."
  def endpoints do
    %{
      discovery: [
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
            "List tasks; optional filters (column_id, status, type, priority, assigned_to_id, parent, updated_since) and cursor pagination (limit, cursor -> meta.next_cursor). For incremental sync with updated_since, read the Incremental sync caveats in the docs first: full view only, bound from server-stamped updated_at with an overlap, upsert by id",
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
          path: "/api/tasks/:id/comments",
          description:
            "List a task's comments, oldest first: the most recent limit (default 50, max 200), with meta.has_more when older ones exist. GET /api/tasks/:id carries comment_count",
          auth_required: true,
          documentation_url: "#{@docs_base_url}/docs/api/get_tasks_id_comments.md"
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
            "Complete a task - REQUIRES after_doing_result parameter. changed_files in the body is silently ignored; use PUT /api/tasks/:id/changed_files instead.",
          required_parameters: ["after_doing_result"],
          hook_validation_required: true,
          returns_hooks: ["after_doing", "before_review", "after_review (conditional)"],
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
          description: "Finalize review",
          returns_hooks: ["after_review (if approved)"],
          auth_required: true,
          documentation_url: "#{@docs_base_url}/docs/api/patch_tasks_id_mark_reviewed.md"
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
