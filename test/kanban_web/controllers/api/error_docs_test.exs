defmodule KanbanWeb.API.ErrorDocsTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.API.ErrorDocs
  alias KanbanWeb.DocAnchors

  @error_docs_source "lib/kanban_web/controllers/api/error_docs.ex"

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
               "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/AI-WORKFLOW.md#task-completion"

      refute Map.has_key?(result, :related_docs)

      assert "Task must be in 'in_progress' or 'blocked' status to complete" in result.common_causes
      assert "You may need to claim the task first" in result.common_causes
      assert "Task may already be completed" in result.common_causes
    end

    test "provides documentation for not authorized to complete" do
      result = ErrorDocs.get_docs(:not_authorized_to_complete)

      assert result.documentation =~
               "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/AI-WORKFLOW.md#task-completion"

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
               "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/REVIEW-WORKFLOW.md#when-needs_review--true-human-review-required"

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
               "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/TASK-WRITING-GUIDE.md#key_files---files-that-will-be-modified"
    end

    test "returns single URL when multiple fields map to same doc" do
      result = ErrorDocs.get_docs(:validation_error, fields: [:why, :what, :where_context])

      assert result ==
               "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/TASK-WRITING-GUIDE.md#why-what-and-where_context---purpose-change-and-location"
    end

    test "returns list of URLs for fields from different docs" do
      result = ErrorDocs.get_docs(:validation_error, fields: [:key_files, :required_capabilities])

      assert is_list(result)
      assert length(result) == 2

      assert "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/TASK-WRITING-GUIDE.md#key_files---files-that-will-be-modified" in result

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

      assert "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/TASK-WRITING-GUIDE.md#key_files---files-that-will-be-modified" in result

      assert "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/TASK-WRITING-GUIDE.md#verification_steps---how-to-prove-the-task-is-done" in result

      assert "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/TASK-WRITING-GUIDE.md#acceptance_criteria---definition-of-done" in result
    end

    test "filters out unknown fields" do
      result = ErrorDocs.get_docs(:validation_error, fields: [:unknown_field, :key_files])

      assert result ==
               "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/TASK-WRITING-GUIDE.md#key_files---files-that-will-be-modified"
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
    # (D356) A full column on POST /api/tasks must point at the create
    # endpoint's 422 section, not the generic README fallback.
    test "provides documentation for a WIP limit rejection" do
      result = ErrorDocs.get_docs(:wip_limit_reached)

      assert result.documentation ==
               "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/post_tasks.md#unprocessable-entity-422"

      assert [_ | _] = result.common_causes
      assert Enum.any?(result.common_causes, &String.contains?(&1, "WIP limit"))
      assert Enum.any?(result.common_causes, &String.contains?(&1, "goals are never counted"))
      refute Map.has_key?(result, :getting_started)
    end

    test "provides documentation for forbidden errors" do
      result = ErrorDocs.get_docs(:forbidden)

      assert result.documentation =~
               "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/AUTHENTICATION.md"

      assert "Resource does not belong to your board" in result.common_causes
      assert "Check that you're using the correct API token" in result.common_causes
      assert "Verify board_id in your requests" in result.common_causes
    end

    # (D227) The point of the clause is that it is NOT the default fallback:
    # a refused PATCH gets the update endpoint's own docs, not the README.
    test "provides documentation for a refused forbidden-field update" do
      result = ErrorDocs.get_docs(:update_forbidden_field)

      assert result.documentation ==
               "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/patch_tasks_id.md"

      assert Enum.any?(result.common_causes, &String.contains?(&1, "/api/tasks/claim"))
      assert Enum.any?(result.common_causes, &String.contains?(&1, "identifier"))
      assert Enum.any?(result.common_causes, &String.contains?(&1, "changed nothing"))

      # The verdict and its attribution are called out separately because only
      # the verdict has no API writer at all. Naming mark_reviewed for
      # review_status would send a caller somewhere that rejects them for a
      # different reason (it requires review_status to already be set), while
      # reviewed_by_id genuinely is written there — one blanket sentence cannot
      # be true of both.
      verdict_cause = Enum.find(result.common_causes, &String.contains?(&1, "review_status"))

      assert verdict_cause =~ "board UI"
      refute verdict_cause =~ "mark_reviewed"
      refute verdict_cause =~ "reviewed_by_id"

      attribution_cause =
        Enum.find(result.common_causes, &String.contains?(&1, "reviewed_by_id"))

      assert attribution_cause =~ "stamps"
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

  # (D361) API errors hand agents a documentation URL so they can self-correct.
  # These tests pin every emitted URL to a real file under docs/ and, when it
  # carries a fragment, to a heading (or explicit HTML anchor) in that file —
  # so a doc heading and a code link can no longer drift apart unnoticed.
  describe "documentation anchor contract" do
    test "every emitted doc URL resolves to an existing file and heading" do
      urls =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.flat_map(fn path -> path |> File.read!() |> DocAnchors.source_doc_links() end)

      # Non-vacuity: error_docs.ex alone writes 23 anchored links today, and
      # the agent onboarding module adds one more.
      assert length(urls) >= 24
      assert Enum.any?(urls, &String.contains?(&1, "MULTI-AGENT-INSTRUCTIONS.md#"))

      assert broken_links(urls) == []
    end

    test "every get_docs context and validation field link passes the anchor check" do
      source = File.read!(@error_docs_source)

      contexts =
        ~r/^\s*def get_docs\(:(\w+)/m
        |> Regex.scan(source, capture: :all_but_first)
        |> Enum.map(fn [name] -> String.to_existing_atom(name) end)
        |> Enum.uniq()

      fields =
        ~r/"(\w+)" =>\s+"#\{@docs_base_url\}/
        |> Regex.scan(source, capture: :all_but_first)
        |> List.flatten()

      # Non-vacuity: the scans must find the clauses and the field map, so a
      # renamed pattern cannot silently turn this into a test of nothing.
      assert :no_tasks_available in contexts
      assert :validation_error in contexts
      assert length(contexts) >= 25
      assert "key_files" in fields
      assert length(fields) >= 13

      results =
        Enum.map(contexts, &ErrorDocs.get_docs(&1, identifier: "W1")) ++
          [
            ErrorDocs.get_docs(:unknown_error_type),
            ErrorDocs.get_docs(:validation_error, fields: fields),
            ErrorDocs.get_docs(:validation_error, fields: [])
          ] ++ Enum.map(fields, &ErrorDocs.get_docs(:validation_error, fields: [&1]))

      urls = results |> DocAnchors.flatten_urls() |> Enum.uniq()

      assert Enum.any?(urls, &String.contains?(&1, "#"))
      assert broken_links(urls) == []
    end

    test "corrected anchors point at the intended sections" do
      prefix = DocAnchors.docs_url_prefix()

      assert ErrorDocs.get_docs(:no_tasks_available).documentation ==
               prefix <> "AI-WORKFLOW.md#claiming-tasks"

      assert ErrorDocs.get_docs(:assigned_to_other_user).documentation ==
               prefix <> "AI-WORKFLOW.md#claiming-tasks"

      assert ErrorDocs.get_docs(:completion_validation_failed).documentation ==
               prefix <> "AI-WORKFLOW.md#task-completion"

      assert (prefix <> "AI-WORKFLOW.md#hook-system") in ErrorDocs.get_docs(
               :hook_validation_failed
             ).related_docs

      assert ErrorDocs.get_docs(:invalid_review_status).documentation ==
               prefix <> "REVIEW-WORKFLOW.md#review-statuses"

      assert ErrorDocs.get_docs(:validation_error, fields: [:dependencies]) ==
               prefix <> "TASK-WRITING-GUIDE.md#dependencies---tasks-that-must-complete-first"

      assert ErrorDocs.get_docs(:validation_error, fields: [:complexity]) ==
               prefix <> "TASK-WRITING-GUIDE.md#complexity---size-estimate"

      assert ErrorDocs.get_docs(:validation_error, fields: [:priority]) ==
               prefix <> "TASK-WRITING-GUIDE.md#priority---order-of-work"

      assert ErrorDocs.get_docs(:validation_error, fields: [:testing_strategy]) ==
               prefix <> "TASK-WRITING-GUIDE.md#testing_strategy---overall-testing-approach"

      assert ErrorDocs.get_docs(:validation_error, fields: [:integration_points]) ==
               prefix <> "TASK-WRITING-GUIDE.md#integration_points---systems-the-task-touches"
    end

    test "existing valid anchors still resolve unchanged" do
      prefix = DocAnchors.docs_url_prefix()

      for url <- [
            prefix <> "AI-WORKFLOW.md#completion-validation",
            prefix <> "TASK-WRITING-GUIDE.md#task-types",
            prefix <> "api/patch_tasks_id_complete.md#completion-validation-format-g65",
            prefix <> "MULTI-AGENT-INSTRUCTIONS.md#manual-installation"
          ] do
        assert DocAnchors.check_url(url) == :ok, url
      end
    end

    test "fails when an emitted anchor has no matching heading" do
      prefix = DocAnchors.docs_url_prefix()

      for old <- [
            "AI-WORKFLOW.md#completing-tasks",
            "AI-WORKFLOW.md#hook-execution",
            "REVIEW-WORKFLOW.md#human-review-process",
            "TASK-WRITING-GUIDE.md#key-files",
            "TASK-WRITING-GUIDE.md#why-what-where"
          ] do
        url = prefix <> old
        assert {:error, message} = DocAnchors.check_url(url)
        assert message =~ url
        assert message =~ "matches no heading"
      end
    end

    test "fails with the URL named when the file is missing, off-host or outside docs/" do
      prefix = DocAnchors.docs_url_prefix()

      missing = prefix <> "NO-SUCH-GUIDE.md#anything"
      assert {:error, message} = DocAnchors.check_url(missing)
      assert message =~ missing
      assert message =~ "does not exist"

      off_host = "https://example.com/docs/AI-WORKFLOW.md#claiming-tasks"
      assert {:error, message} = DocAnchors.check_url(off_host)
      assert message =~ off_host

      for escape <- ["../mix.exs", "../README.md", "api/../../README.md", "/etc/passwd.md"] do
        url = prefix <> escape
        assert {:error, message} = DocAnchors.check_url(url)
        assert message =~ "outside the allowed docs/ pattern"
      end
    end

    test "unanchored and default links only require the file" do
      prefix = DocAnchors.docs_url_prefix()

      assert ErrorDocs.get_docs(:validation_error, fields: []) ==
               prefix <> "TASK-WRITING-GUIDE.md"

      assert DocAnchors.check_url(prefix <> "TASK-WRITING-GUIDE.md") == :ok

      fallback = ErrorDocs.get_docs(:unknown_error_type)
      assert DocAnchors.check_url(fallback.documentation) == :ok
      assert DocAnchors.check_url(fallback.getting_started) == :ok
    end

    test "heading slug helper follows the GitHub rule" do
      assert DocAnchors.slug("Hook System") == "hook-system"

      assert DocAnchors.slug("`key_files` - Files that will be modified") ==
               "key_files---files-that-will-be-modified"

      assert DocAnchors.slug("Why, What, Where") == "why-what-where"

      assert DocAnchors.slug("When needs_review = true (Human Review Required)") ==
               "when-needs_review--true-human-review-required"

      assert DocAnchors.slug("Completion Validation Requirements (G65)") ==
               "completion-validation-requirements-g65"

      assert DocAnchors.slug("See [the guide](GUIDE.md) **now**") == "see-the-guide-now"

      markdown = """
      # Setup
      ## Setup
      ### Setup ###
      ## Setup-1
      <a id="custom-anchor"></a>
      """

      assert DocAnchors.anchors(markdown) ==
               MapSet.new(["setup", "setup-1", "setup-2", "setup-1-1", "custom-anchor"])
    end

    test "flattens string, list and map results and ignores fenced headings" do
      url = DocAnchors.docs_url_prefix() <> "AI-WORKFLOW.md"

      assert DocAnchors.flatten_urls(url) == [url]
      assert DocAnchors.flatten_urls([url, "not a url"]) == [url]

      assert DocAnchors.flatten_urls(%{documentation: url, related_docs: [url], count: 3}) ==
               [url, url]

      assert DocAnchors.flatten_urls(:atom) == []

      markdown = """
      ## Real Heading

      ```markdown
      ## Inside Fence
      ```bash
      ## Still Inside
      ```
      ## After Fence

      ~~~~
      ## Tilde Fenced
      ~~~
      ## Short Closer Does Not Close
      ~~~~
          ## Indented Code
      """

      assert DocAnchors.anchors(markdown) == MapSet.new(["real-heading", "after-fence"])
    end
  end

  defp broken_links(urls) do
    Enum.flat_map(urls, fn url ->
      case DocAnchors.check_url(url) do
        :ok -> []
        {:error, message} -> [message]
      end
    end)
  end
end
