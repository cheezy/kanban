defmodule KanbanWeb.API.ErrorDocs do
  @moduledoc """
  Provides contextual documentation links for API errors to help agents
  understand and fix issues quickly.
  """

  @docs_base_url "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs"

  @doc """
  Returns a documentation link for a given error context.
  """
  def get_docs(context, opts \\ [])

  # Task claiming errors
  def get_docs(:no_tasks_available, _opts) do
    %{
      documentation: "#{@docs_base_url}/AI-WORKFLOW.md#claiming-tasks",
      related_docs: [
        "#{@docs_base_url}/AGENT-CAPABILITIES.md"
      ],
      common_causes: [
        "No tasks in Ready column",
        "All tasks require capabilities you don't have",
        "All tasks are blocked by dependencies",
        "All tasks are already claimed by other agents"
      ]
    }
  end

  def get_docs(:task_not_claimable, opts) do
    identifier = Keyword.get(opts, :identifier)

    %{
      documentation: "#{@docs_base_url}/AI-WORKFLOW.md#claiming-tasks",
      related_docs: [
        "#{@docs_base_url}/AGENT-CAPABILITIES.md"
      ],
      common_causes:
        if identifier do
          [
            "Task '#{identifier}' is already claimed by another agent",
            "Task '#{identifier}' is blocked by uncompleted dependencies",
            "Task '#{identifier}' requires capabilities you don't have",
            "Task '#{identifier}' does not exist on this board"
          ]
        else
          [
            "Task is already claimed by another agent",
            "Task is blocked by uncompleted dependencies",
            "Task requires capabilities you don't have"
          ]
        end
    }
  end

  # Task completion errors
  def get_docs(:invalid_status_for_complete, _opts) do
    %{
      documentation: "#{@docs_base_url}/AI-WORKFLOW.md#completing-tasks",
      common_causes: [
        "Task must be in 'in_progress' or 'blocked' status to complete",
        "You may need to claim the task first",
        "Task may already be completed"
      ]
    }
  end

  def get_docs(:not_authorized_to_complete, _opts) do
    %{
      documentation: "#{@docs_base_url}/AI-WORKFLOW.md#completing-tasks",
      common_causes: [
        "You can only complete tasks that are assigned to you",
        "Claim the task first using POST /api/tasks/claim"
      ]
    }
  end

  # Unclaim errors
  def get_docs(:not_authorized_to_unclaim, _opts) do
    %{
      documentation: "#{@docs_base_url}/UNCLAIM-TASKS.md",
      common_causes: [
        "You can only unclaim tasks that you claimed",
        "Task may be assigned to a different agent or user"
      ]
    }
  end

  def get_docs(:task_not_claimed, _opts) do
    %{
      documentation: "#{@docs_base_url}/UNCLAIM-TASKS.md",
      common_causes: [
        "Task is not currently claimed by anyone",
        "Task may already be unclaimed or completed"
      ]
    }
  end

  # Hook execution errors
  def get_docs(:hook_validation_failed, _opts) do
    %{
      documentation: "#{@docs_base_url}/AGENT-HOOK-EXECUTION-GUIDE.md",
      related_docs: [
        "#{@docs_base_url}/AI-WORKFLOW.md#hook-execution"
      ],
      common_causes: [
        "Hook result not provided in request (required parameter missing)",
        "Hook result missing required fields (exit_code, output, duration_ms)",
        "Blocking hook failed with non-zero exit code",
        "Hook result is not a properly formatted map"
      ],
      correct_format: %{
        before_doing_result: %{
          exit_code: 0,
          output: "Hook execution output",
          duration_ms: 1234
        },
        after_doing_result: %{
          exit_code: 0,
          output: "All tests passed\nmix format --check-formatted\nmix credo --strict",
          duration_ms: 45_678
        }
      }
    }
  end

  # Review workflow errors
  def get_docs(:invalid_column_for_review, _opts) do
    %{
      documentation: "#{@docs_base_url}/REVIEW-WORKFLOW.md",
      common_causes: [
        "Task must be in Review column to mark as reviewed",
        "Complete the task first to move it to Review"
      ]
    }
  end

  def get_docs(:review_not_performed, _opts) do
    %{
      documentation: "#{@docs_base_url}/REVIEW-WORKFLOW.md#human-review-process",
      common_causes: [
        "A human reviewer must set review_status before calling mark_reviewed",
        "Wait for human to approve/reject the review",
        "Check task.review_status field"
      ]
    }
  end

  def get_docs(:invalid_review_status, _opts) do
    %{
      documentation: "#{@docs_base_url}/REVIEW-WORKFLOW.md#review-statuses",
      common_causes: [
        "review_status must be 'approved', 'changes_requested', or 'rejected'",
        "Only humans can set review_status"
      ]
    }
  end

  # Mark done errors
  def get_docs(:invalid_column_for_mark_done, _opts) do
    %{
      documentation: "#{@docs_base_url}/api/patch_tasks_id_mark_done.md",
      common_causes: [
        "Task must be in Review column to mark as done",
        "This endpoint bypasses the review process",
        "Use PATCH /api/tasks/:id/complete for normal workflow"
      ]
    }
  end

  # Batch create errors
  def get_docs(:batch_create_invalid_root_key, _opts) do
    %{
      documentation: "#{@docs_base_url}/api/post_tasks_batch.md",
      common_causes: [
        "Used 'tasks' as the root key instead of 'goals'",
        "The batch endpoint expects {\"goals\": [...]} not {\"tasks\": [...]}"
      ],
      correct_format: "See the 'example' field in this response"
    }
  end

  def get_docs(:batch_create_missing_goals_key, _opts) do
    %{
      documentation: "#{@docs_base_url}/api/post_tasks_batch.md",
      common_causes: [
        "Missing 'goals' key in request body",
        "Request body may be empty or malformed",
        "The batch endpoint requires {\"goals\": [...]}"
      ],
      correct_format: "See the 'example' field in this response"
    }
  end

  # Create errors
  def get_docs(:create_invalid_root_key, _opts) do
    %{
      documentation: "#{@docs_base_url}/api/post_tasks.md",
      common_causes: [
        "Used 'data' as the root key instead of 'task'",
        "The create endpoint expects {\"task\": {...}} not {\"data\": {...}}"
      ],
      correct_format: "See the 'example' field in this response"
    }
  end

  def get_docs(:create_missing_task_key, _opts) do
    %{
      documentation: "#{@docs_base_url}/api/post_tasks.md",
      common_causes: [
        "Missing 'task' key in request body",
        "Request body may be empty or malformed",
        "The create endpoint requires {\"task\": {...}}"
      ],
      correct_format: "See the 'example' field in this response"
    }
  end

  # Update errors
  def get_docs(:update_invalid_root_key, _opts) do
    %{
      documentation: "#{@docs_base_url}/api/patch_tasks_id.md",
      common_causes: [
        "Used 'data' as the root key instead of 'task'",
        "The update endpoint expects {\"task\": {...}} not {\"data\": {...}}"
      ],
      correct_format: "See the 'example' field in this response"
    }
  end

  def get_docs(:update_missing_task_key, _opts) do
    %{
      documentation: "#{@docs_base_url}/api/patch_tasks_id.md",
      common_causes: [
        "Missing 'task' key in request body",
        "Request body may be empty or malformed",
        "The update endpoint requires {\"task\": {...}}"
      ],
      correct_format: "See the 'example' field in this response"
    }
  end

  # Validation errors (used by TaskJSON.error/1)
  def get_docs(:validation_error, opts) do
    field_errors = Keyword.get(opts, :fields, [])

    field_docs = %{
      "key_files" => "#{@docs_base_url}/TASK-WRITING-GUIDE.md#key-files",
      "verification_steps" => "#{@docs_base_url}/TASK-WRITING-GUIDE.md#verification-steps",
      "acceptance_criteria" => "#{@docs_base_url}/TASK-WRITING-GUIDE.md#acceptance-criteria",
      "dependencies" => "#{@docs_base_url}/TASK-WRITING-GUIDE.md#dependencies",
      "required_capabilities" => "#{@docs_base_url}/AGENT-CAPABILITIES.md",
      "complexity" => "#{@docs_base_url}/TASK-WRITING-GUIDE.md#complexity-estimation",
      "priority" => "#{@docs_base_url}/TASK-WRITING-GUIDE.md#priority",
      "type" => "#{@docs_base_url}/TASK-WRITING-GUIDE.md#task-types",
      "testing_strategy" => "#{@docs_base_url}/TASK-WRITING-GUIDE.md#testing-strategy",
      "integration_points" => "#{@docs_base_url}/TASK-WRITING-GUIDE.md#integration-points",
      "why" => "#{@docs_base_url}/TASK-WRITING-GUIDE.md#why-what-where",
      "what" => "#{@docs_base_url}/TASK-WRITING-GUIDE.md#why-what-where",
      "where_context" => "#{@docs_base_url}/TASK-WRITING-GUIDE.md#why-what-where"
    }

    links =
      field_errors
      |> Enum.map(&field_docs[to_string(&1)])
      |> Enum.filter(&(&1 != nil))
      |> Enum.uniq()

    case links do
      [] -> "#{@docs_base_url}/TASK-WRITING-GUIDE.md"
      [single_link] -> single_link
      multiple_links -> multiple_links
    end
  end

  # Forbidden/Authorization errors
  def get_docs(:forbidden, _opts) do
    %{
      documentation: "#{@docs_base_url}/AUTHENTICATION.md",
      common_causes: [
        "Resource does not belong to your board",
        "Check that you're using the correct API token",
        "Verify board_id in your requests"
      ]
    }
  end

  # Default fallback
  def get_docs(_context, _opts) do
    %{
      documentation: "#{@docs_base_url}/api/README.md",
      getting_started: "#{@docs_base_url}/GETTING-STARTED-WITH-AI.md"
    }
  end

  @doc """
  Enhances an error response map with documentation links.
  """
  def add_docs_to_error(error_map, context, opts \\ []) when is_map(error_map) do
    docs = get_docs(context, opts)
    Map.merge(error_map, docs)
  end
end
