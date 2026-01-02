defmodule KanbanWeb.API.ErrorDocsTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.API.ErrorDocs

  describe "get_docs/2 for task claiming errors" do
    test "provides documentation for no tasks available" do
      result = ErrorDocs.get_docs(:no_tasks_available)

      assert result.documentation =~
               "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/AI-WORKFLOW.md#claiming-tasks"

      assert result.related_docs == [
               "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/AGENT-CAPABILITIES.md"
             ]

      assert "No tasks in Ready column" in result.common_causes
      assert "All tasks require capabilities you don't have" in result.common_causes
      assert "All tasks are blocked by dependencies" in result.common_causes
      assert "All tasks are already claimed by other agents" in result.common_causes
    end

    test "provides documentation for specific task not claimable with identifier" do
      result = ErrorDocs.get_docs(:task_not_claimable, identifier: "W21")

      assert result.documentation =~
               "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/AI-WORKFLOW.md#claiming-tasks"

      assert result.related_docs == [
               "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/AGENT-CAPABILITIES.md"
             ]

      assert "Task 'W21' is already claimed by another agent" in result.common_causes
      assert "Task 'W21' is blocked by uncompleted dependencies" in result.common_causes
      assert "Task 'W21' requires capabilities you don't have" in result.common_causes
      assert "Task 'W21' does not exist on this board" in result.common_causes
    end

    test "provides documentation for task not claimable without identifier" do
      result = ErrorDocs.get_docs(:task_not_claimable)

      assert result.documentation =~
               "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/AI-WORKFLOW.md#claiming-tasks"

      assert "Task is already claimed by another agent" in result.common_causes
      assert "Task is blocked by uncompleted dependencies" in result.common_causes
      assert "Task requires capabilities you don't have" in result.common_causes
    end
  end

  describe "get_docs/2 for task completion errors" do
    test "provides documentation for invalid status" do
      result = ErrorDocs.get_docs(:invalid_status_for_complete)

      assert result.documentation =~
               "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/AI-WORKFLOW.md#completing-tasks"

      refute Map.has_key?(result, :related_docs)

      assert "Task must be in 'in_progress' or 'blocked' status to complete" in result.common_causes
      assert "You may need to claim the task first" in result.common_causes
      assert "Task may already be completed" in result.common_causes
    end

    test "provides documentation for not authorized to complete" do
      result = ErrorDocs.get_docs(:not_authorized_to_complete)

      assert result.documentation =~
               "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/AI-WORKFLOW.md#completing-tasks"

      refute Map.has_key?(result, :related_docs)

      assert "You can only complete tasks that are assigned to you" in result.common_causes
      assert "Claim the task first using POST /api/tasks/claim" in result.common_causes
    end
  end

  describe "get_docs/2 for task unclaim errors" do
    test "provides documentation for not authorized to unclaim" do
      result = ErrorDocs.get_docs(:not_authorized_to_unclaim)

      assert result.documentation =~
               "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/UNCLAIM-TASKS.md"

      refute Map.has_key?(result, :related_docs)

      assert "You can only unclaim tasks that you claimed" in result.common_causes
      assert "Task may be assigned to a different agent or user" in result.common_causes
    end

    test "provides documentation for task not claimed" do
      result = ErrorDocs.get_docs(:task_not_claimed)

      assert result.documentation =~
               "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/UNCLAIM-TASKS.md"

      refute Map.has_key?(result, :related_docs)

      assert "Task is not currently claimed by anyone" in result.common_causes
      assert "Task may already be unclaimed or completed" in result.common_causes
    end
  end

  describe "get_docs/2 for review errors" do
    test "provides documentation for invalid column for review" do
      result = ErrorDocs.get_docs(:invalid_column_for_review)

      assert result.documentation =~
               "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/REVIEW-WORKFLOW.md"

      refute Map.has_key?(result, :related_docs)

      assert "Task must be in Review column to mark as reviewed" in result.common_causes
      assert "Complete the task first to move it to Review" in result.common_causes
    end

    test "provides documentation for review not performed" do
      result = ErrorDocs.get_docs(:review_not_performed)

      assert result.documentation =~
               "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/REVIEW-WORKFLOW.md#human-review-process"

      refute Map.has_key?(result, :related_docs)

      assert "A human reviewer must set review_status before calling mark_reviewed" in result.common_causes
      assert "Wait for human to approve/reject the review" in result.common_causes
      assert "Check task.review_status field" in result.common_causes
    end

    test "provides documentation for invalid review status" do
      result = ErrorDocs.get_docs(:invalid_review_status)

      assert result.documentation =~
               "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/REVIEW-WORKFLOW.md#review-statuses"

      refute Map.has_key?(result, :related_docs)

      assert "review_status must be 'approved', 'changes_requested', or 'rejected'" in result.common_causes
      assert "Only humans can set review_status" in result.common_causes
    end

    test "provides documentation for invalid column for mark done" do
      result = ErrorDocs.get_docs(:invalid_column_for_mark_done)

      assert result.documentation =~
               "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/patch_tasks_id_mark_done.md"

      refute Map.has_key?(result, :related_docs)

      assert "Task must be in Review column to mark as done" in result.common_causes
      assert "This endpoint bypasses the review process" in result.common_causes
      assert "Use PATCH /api/tasks/:id/complete for normal workflow" in result.common_causes
    end
  end

  describe "get_docs/2 for validation errors" do
    test "returns single URL when no fields specified" do
      result = ErrorDocs.get_docs(:validation_error, fields: [])

      assert result ==
               "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/TASK-WRITING-GUIDE.md"
    end

    test "returns single URL for one field" do
      result = ErrorDocs.get_docs(:validation_error, fields: [:key_files])

      assert result ==
               "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/TASK-WRITING-GUIDE.md#key-files"
    end

    test "returns single URL when multiple fields map to same doc" do
      result = ErrorDocs.get_docs(:validation_error, fields: [:why, :what, :where_context])

      assert result ==
               "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/TASK-WRITING-GUIDE.md#why-what-where"
    end

    test "returns list of URLs for fields from different docs" do
      result = ErrorDocs.get_docs(:validation_error, fields: [:key_files, :required_capabilities])

      assert is_list(result)
      assert length(result) == 2

      assert "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/TASK-WRITING-GUIDE.md#key-files" in result

      assert "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/AGENT-CAPABILITIES.md" in result
    end

    test "returns list of unique URLs for multiple fields" do
      result =
        ErrorDocs.get_docs(:validation_error,
          fields: [:key_files, :verification_steps, :acceptance_criteria]
        )

      assert is_list(result)

      # All three fields are in the same doc with different anchors
      assert length(result) == 3

      assert "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/TASK-WRITING-GUIDE.md#key-files" in result

      assert "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/TASK-WRITING-GUIDE.md#verification-steps" in result

      assert "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/TASK-WRITING-GUIDE.md#acceptance-criteria" in result
    end

    test "filters out unknown fields" do
      result = ErrorDocs.get_docs(:validation_error, fields: [:unknown_field, :key_files])

      assert result ==
               "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/TASK-WRITING-GUIDE.md#key-files"
    end

    test "handles all supported validation fields" do
      fields = [
        :key_files,
        :verification_steps,
        :acceptance_criteria,
        :dependencies,
        :required_capabilities,
        :complexity,
        :priority,
        :type,
        :testing_strategy,
        :integration_points,
        :why,
        :what,
        :where_context
      ]

      result = ErrorDocs.get_docs(:validation_error, fields: fields)

      assert is_list(result)
      # Should include multiple unique URLs
      assert length(result) > 1
    end
  end

  describe "get_docs/2 for other error types" do
    test "provides documentation for forbidden errors" do
      result = ErrorDocs.get_docs(:forbidden)

      assert result.documentation =~
               "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/AUTHENTICATION.md"

      assert "Resource does not belong to your board" in result.common_causes
      assert "Check that you're using the correct API token" in result.common_causes
      assert "Verify board_id in your requests" in result.common_causes
    end

    test "provides default documentation for unknown contexts" do
      result = ErrorDocs.get_docs(:unknown_error_type)

      assert result.documentation ==
               "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/README.md"

      assert result.getting_started ==
               "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/GETTING-STARTED-WITH-AI.md"
    end
  end

  describe "add_docs_to_error/3" do
    test "merges documentation into error map for no tasks available" do
      error_map = %{error: "No tasks available"}
      result = ErrorDocs.add_docs_to_error(error_map, :no_tasks_available)

      assert result.error == "No tasks available"
      assert result.documentation
      assert result.related_docs
      assert result.common_causes
    end

    test "merges documentation into error map with identifier" do
      error_map = %{error: "Task not claimable"}
      result = ErrorDocs.add_docs_to_error(error_map, :task_not_claimable, identifier: "W21")

      assert result.error == "Task not claimable"
      assert result.documentation
      assert result.common_causes
      assert Enum.any?(result.common_causes, &String.contains?(&1, "W21"))
    end

    test "preserves all fields from original error map" do
      error_map = %{error: "Something failed", details: "More info", code: 123}
      result = ErrorDocs.add_docs_to_error(error_map, :no_tasks_available)

      assert result.error == "Something failed"
      assert result.details == "More info"
      assert result.code == 123
      assert result.documentation
    end
  end
end
