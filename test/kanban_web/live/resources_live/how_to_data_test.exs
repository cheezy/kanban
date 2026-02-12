defmodule KanbanWeb.ResourcesLive.HowToDataTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.ResourcesLive.HowToData

  describe "all_how_tos/0" do
    test "returns a list of how-to guides" do
      how_tos = HowToData.all_how_tos()

      assert is_list(how_tos)
      assert length(how_tos) >= 8
    end

    test "each how-to has required fields" do
      for how_to <- HowToData.all_how_tos() do
        assert Map.has_key?(how_to, :id)
        assert Map.has_key?(how_to, :title)
        assert Map.has_key?(how_to, :description)
        assert Map.has_key?(how_to, :tags)
        assert Map.has_key?(how_to, :content_type)
        assert Map.has_key?(how_to, :reading_time)
        assert Map.has_key?(how_to, :steps)

        assert is_binary(how_to.id)
        assert is_binary(how_to.title)
        assert is_binary(how_to.description)
        assert is_list(how_to.tags)
        assert is_binary(how_to.content_type)
        assert is_integer(how_to.reading_time)
        assert is_list(how_to.steps)
      end
    end

    test "each step has required fields" do
      for how_to <- HowToData.all_how_tos() do
        for step <- how_to.steps do
          assert Map.has_key?(step, :title)
          assert Map.has_key?(step, :content)

          assert is_binary(step.title)
          assert is_binary(step.content)
        end
      end
    end
  end

  describe "all_tags/0" do
    test "returns a list of tags" do
      tags = HowToData.all_tags()

      assert is_list(tags)
      assert "developer" in tags
      assert "getting-started" in tags
      assert "beginner" in tags
    end
  end

  describe "get_how_to/1" do
    test "returns {:ok, how_to} for valid id" do
      assert {:ok, how_to} = HowToData.get_how_to("creating-your-first-board")
      assert how_to.title == "Creating Your First Board"
    end

    test "returns :error for invalid id" do
      assert :error == HowToData.get_how_to("nonexistent-guide")
    end
  end

  describe "type_icon/1" do
    test "returns icon for guide" do
      assert HowToData.type_icon("guide") == "hero-book-open"
    end

    test "returns icon for tutorial" do
      assert HowToData.type_icon("tutorial") == "hero-academic-cap"
    end

    test "returns icon for reference" do
      assert HowToData.type_icon("reference") == "hero-document-text"
    end

    test "returns icon for video" do
      assert HowToData.type_icon("video") == "hero-play-circle"
    end

    test "returns default icon for unknown type" do
      assert HowToData.type_icon("unknown") == "hero-document"
    end
  end

  describe "format_tag/1" do
    test "formats single word tag" do
      assert HowToData.format_tag("developer") == "Developer"
    end

    test "formats multi-word tag with hyphens" do
      assert HowToData.format_tag("getting-started") == "Getting Started"
    end

    test "formats tag with multiple hyphens" do
      assert HowToData.format_tag("some-long-tag-name") == "Some Long Tag Name"
    end
  end

  describe "get_navigation/1" do
    test "returns previous and next how-tos based on shared tags" do
      {:ok, how_to} = HowToData.get_how_to("understanding-columns")
      {prev, next} = HowToData.get_navigation(how_to)

      # First how-to in getting-started should be creating-your-first-board
      assert prev.id == "creating-your-first-board"
      assert next != nil
    end

    test "returns nil for previous when at beginning" do
      {:ok, how_to} = HowToData.get_how_to("creating-your-first-board")
      {prev, _next} = HowToData.get_navigation(how_to)

      assert prev == nil
    end
  end

  describe "developer guides content" do
    test "all 4 developer guides exist" do
      developer_guides =
        HowToData.all_how_tos()
        |> Enum.filter(&("developer" in &1.tags))

      assert length(developer_guides) == 4

      guide_ids = Enum.map(developer_guides, & &1.id)
      assert "setting-up-hooks" in guide_ids
      assert "api-authentication" in guide_ids
      assert "claim-complete-workflow" in guide_ids
      assert "debugging-hooks" in guide_ids
    end

    test "setting-up-hooks guide has complete content" do
      {:ok, guide} = HowToData.get_how_to("setting-up-hooks")

      assert guide.title == "Setting Up Hook Execution"
      assert "developer" in guide.tags
      assert "hooks" in guide.tags
      assert guide.content_type == "tutorial"
      assert length(guide.steps) >= 3
    end

    test "api-authentication guide has complete content" do
      {:ok, guide} = HowToData.get_how_to("api-authentication")

      assert guide.title == "Configuring API Authentication"
      assert "developer" in guide.tags
      assert "api" in guide.tags
      assert guide.content_type == "tutorial"
      assert length(guide.steps) >= 3
    end

    test "claim-complete-workflow guide has complete content" do
      {:ok, guide} = HowToData.get_how_to("claim-complete-workflow")

      assert guide.title == "Understanding Claim/Complete Workflow"
      assert "developer" in guide.tags
      assert "workflow" in guide.tags
      assert guide.content_type == "guide"
      assert length(guide.steps) >= 4

      # Verify it has key workflow content
      all_content = Enum.map_join(guide.steps, "\n", & &1.content)
      assert String.contains?(all_content, "claim")
      assert String.contains?(all_content, "complete")
      assert String.contains?(all_content, "hook")
    end

    test "debugging-hooks guide has complete content" do
      {:ok, guide} = HowToData.get_how_to("debugging-hooks")

      assert guide.title == "Debugging Hook Failures"
      assert "developer" in guide.tags
      assert "troubleshooting" in guide.tags
      assert guide.content_type == "guide"
      assert length(guide.steps) >= 3

      # Verify it has troubleshooting content
      all_content = Enum.map_join(guide.steps, "\n", & &1.content)
      assert String.contains?(all_content, "exit")
      assert String.contains?(all_content, "fail")
    end

    test "developer guides have appropriate reading times" do
      {:ok, hooks} = HowToData.get_how_to("setting-up-hooks")
      {:ok, auth} = HowToData.get_how_to("api-authentication")
      {:ok, workflow} = HowToData.get_how_to("claim-complete-workflow")
      {:ok, debug} = HowToData.get_how_to("debugging-hooks")

      # Reading times should be reasonable for technical content
      assert hooks.reading_time >= 5
      assert auth.reading_time >= 3
      assert workflow.reading_time >= 5
      assert debug.reading_time >= 3
    end
  end

  describe "getting started guides content" do
    test "all 4 getting-started guides exist" do
      getting_started_guides =
        HowToData.all_how_tos()
        |> Enum.filter(&("getting-started" in &1.tags))

      assert length(getting_started_guides) == 4

      guide_ids = Enum.map(getting_started_guides, & &1.id)
      assert "creating-your-first-board" in guide_ids
      assert "understanding-columns" in guide_ids
      assert "adding-your-first-task" in guide_ids
      assert "inviting-team-members" in guide_ids
    end

    test "getting-started guides are tagged as beginner" do
      getting_started_guides =
        HowToData.all_how_tos()
        |> Enum.filter(&("getting-started" in &1.tags))

      for guide <- getting_started_guides do
        assert "beginner" in guide.tags,
               "Guide #{guide.id} should have beginner tag"
      end
    end

    test "creating-your-first-board guide has complete content" do
      {:ok, guide} = HowToData.get_how_to("creating-your-first-board")

      assert guide.title == "Creating Your First Board"
      assert "getting-started" in guide.tags
      assert "beginner" in guide.tags
      assert "boards" in guide.tags
      assert guide.content_type == "guide"
      assert length(guide.steps) >= 3

      # Verify key content exists
      all_content = Enum.map_join(guide.steps, "\n", & &1.content)
      assert String.contains?(all_content, "New Board")
      assert String.contains?(all_content, "name")
    end

    test "understanding-columns guide has complete content" do
      {:ok, guide} = HowToData.get_how_to("understanding-columns")

      assert guide.title == "Understanding Board Columns and Workflow"
      assert "getting-started" in guide.tags
      assert "beginner" in guide.tags
      assert "workflow" in guide.tags
      assert guide.content_type == "guide"
      assert length(guide.steps) >= 3

      # Verify key content exists
      all_content = Enum.map_join(guide.steps, "\n", & &1.content)
      assert String.contains?(all_content, "Column")
      assert String.contains?(all_content, "workflow")
    end

    test "adding-your-first-task guide has complete content" do
      {:ok, guide} = HowToData.get_how_to("adding-your-first-task")

      assert guide.title == "Adding Your First Task"
      assert "getting-started" in guide.tags
      assert "beginner" in guide.tags
      assert "tasks" in guide.tags
      assert guide.content_type == "guide"
      assert length(guide.steps) >= 3

      # Verify key content exists
      all_content = Enum.map_join(guide.steps, "\n", & &1.content)
      assert String.contains?(all_content, "Task")
      assert String.contains?(all_content, "Title")
    end

    test "inviting-team-members guide has complete content" do
      {:ok, guide} = HowToData.get_how_to("inviting-team-members")

      assert guide.title == "Adding Team Members to Your Board"
      assert "getting-started" in guide.tags
      assert "beginner" in guide.tags
      assert "collaboration" in guide.tags
      assert guide.content_type == "guide"
      assert length(guide.steps) >= 2

      # Verify key content exists
      all_content = Enum.map_join(guide.steps, "\n", & &1.content)
      assert String.contains?(all_content, "email") or String.contains?(all_content, "invite")

      assert String.contains?(all_content, "permission") or
               String.contains?(all_content, "access")
    end

    test "getting-started guides have appropriate reading times" do
      {:ok, board} = HowToData.get_how_to("creating-your-first-board")
      {:ok, columns} = HowToData.get_how_to("understanding-columns")
      {:ok, task} = HowToData.get_how_to("adding-your-first-task")
      {:ok, invite} = HowToData.get_how_to("inviting-team-members")

      # Reading times should be quick for beginner content
      assert board.reading_time >= 2 and board.reading_time <= 10
      assert columns.reading_time >= 2 and columns.reading_time <= 10
      assert task.reading_time >= 2 and task.reading_time <= 10
      assert invite.reading_time >= 1 and invite.reading_time <= 10
    end

    test "getting-started guides use beginner-friendly language" do
      getting_started_guides =
        HowToData.all_how_tos()
        |> Enum.filter(&("getting-started" in &1.tags))

      for guide <- getting_started_guides do
        # All guides should have descriptions
        assert String.length(guide.description) > 10,
               "Guide #{guide.id} should have a substantial description"

        # All steps should have titles
        for step <- guide.steps do
          assert String.length(step.title) > 0,
                 "Step in #{guide.id} should have a title"

          assert String.length(step.content) > 10,
                 "Step in #{guide.id} should have content"
        end
      end
    end
  end

  describe "non-developer guides content" do
    test "all 3 non-developer guides exist" do
      non_dev_guides =
        HowToData.all_how_tos()
        |> Enum.filter(&("non-developer" in &1.tags))

      assert length(non_dev_guides) == 3

      guide_ids = Enum.map(non_dev_guides, & &1.id)
      assert "writing-tasks-for-ai" in guide_ids
      assert "monitoring-task-progress" in guide_ids
      assert "reviewing-completed-work" in guide_ids
    end

    test "writing-tasks-for-ai guide has complete content" do
      {:ok, guide} = HowToData.get_how_to("writing-tasks-for-ai")

      assert guide.title == "Writing Effective Tasks for AI Agents"
      assert "non-developer" in guide.tags
      assert "ai-agents" in guide.tags
      assert guide.content_type == "guide"
      assert length(guide.steps) >= 3

      # Verify key content
      all_content = Enum.map_join(guide.steps, "\n", & &1.content)
      assert String.contains?(all_content, "title")
      assert String.contains?(all_content, "description")
      assert String.contains?(all_content, "acceptance criteria")
    end

    test "monitoring-task-progress guide has complete content" do
      {:ok, guide} = HowToData.get_how_to("monitoring-task-progress")

      assert guide.title == "Monitoring Task Progress"
      assert "non-developer" in guide.tags
      assert "monitoring" in guide.tags
      assert guide.content_type == "guide"
      assert length(guide.steps) >= 3

      # Verify key content
      all_content = Enum.map_join(guide.steps, "\n", & &1.content)
      assert String.contains?(all_content, "column")
      assert String.contains?(all_content, "progress")
    end

    test "reviewing-completed-work guide has complete content" do
      {:ok, guide} = HowToData.get_how_to("reviewing-completed-work")

      assert guide.title == "Reviewing Completed Work"
      assert "non-developer" in guide.tags
      assert "reviewing" in guide.tags
      assert guide.content_type == "guide"
      assert length(guide.steps) >= 3

      # Verify key content
      all_content = Enum.map_join(guide.steps, "\n", & &1.content)
      assert String.contains?(all_content, "review")
      assert String.contains?(all_content, "approve") or String.contains?(all_content, "Approve")
    end

    test "non-developer guides use accessible language" do
      non_dev_guides =
        HowToData.all_how_tos()
        |> Enum.filter(&("non-developer" in &1.tags))

      for guide <- non_dev_guides do
        # Should have reasonable reading times
        assert guide.reading_time >= 3 and guide.reading_time <= 10

        # All steps should have content
        for step <- guide.steps do
          assert String.length(step.content) > 20,
                 "Step in #{guide.id} should have substantial content"
        end
      end
    end
  end

  describe "best practices guides content" do
    test "all 2 best-practices guides exist" do
      best_practices_guides =
        HowToData.all_how_tos()
        |> Enum.filter(&("best-practices" in &1.tags))

      assert length(best_practices_guides) == 7

      guide_ids = Enum.map(best_practices_guides, & &1.id)
      assert "organizing-with-dependencies" in guide_ids
      assert "using-complexity-priority" in guide_ids
      assert "metrics-dashboard" in guide_ids
      assert "throughput-metrics" in guide_ids
      assert "cycle-time-metrics" in guide_ids
      assert "lead-time-metrics" in guide_ids
      assert "wait-time-metrics" in guide_ids
    end

    test "organizing-with-dependencies guide has complete content" do
      {:ok, guide} = HowToData.get_how_to("organizing-with-dependencies")

      assert guide.title == "Organizing Tasks with Dependencies"
      assert "best-practices" in guide.tags
      assert "dependencies" in guide.tags
      assert guide.content_type == "guide"
      assert length(guide.steps) >= 3

      # Verify key content
      all_content = Enum.map_join(guide.steps, "\n", & &1.content)
      assert String.contains?(all_content, "depend")
      assert String.contains?(all_content, "order")
    end

    test "using-complexity-priority guide has complete content" do
      {:ok, guide} = HowToData.get_how_to("using-complexity-priority")

      assert guide.title == "Using Complexity and Priority Effectively"
      assert "best-practices" in guide.tags
      assert "priority" in guide.tags
      assert guide.content_type == "guide"
      assert length(guide.steps) >= 3

      # Verify key content
      all_content = Enum.map_join(guide.steps, "\n", & &1.content)

      assert String.contains?(all_content, "complexity") or
               String.contains?(all_content, "Complexity")

      assert String.contains?(all_content, "priority") or
               String.contains?(all_content, "Priority")
    end

    test "best-practices guides have actionable content" do
      best_practices_guides =
        HowToData.all_how_tos()
        |> Enum.filter(&("best-practices" in &1.tags))

      for guide <- best_practices_guides do
        # Should have practical reading times
        assert guide.reading_time >= 2 and guide.reading_time <= 10

        # All guides should have multiple steps
        assert length(guide.steps) >= 3,
               "Guide #{guide.id} should have at least 3 steps"
      end
    end
  end

  describe "all_tags/0 includes new tags" do
    test "includes non-developer tag" do
      assert "non-developer" in HowToData.all_tags()
    end

    test "includes best-practices tag" do
      assert "best-practices" in HowToData.all_tags()
    end

    test "includes ai-agents tag" do
      assert "ai-agents" in HowToData.all_tags()
    end

    test "includes monitoring tag" do
      assert "monitoring" in HowToData.all_tags()
    end

    test "includes reviewing tag" do
      assert "reviewing" in HowToData.all_tags()
    end

    test "includes dependencies tag" do
      assert "dependencies" in HowToData.all_tags()
    end

    test "includes priority tag" do
      assert "priority" in HowToData.all_tags()
    end
  end

  describe "total guide count" do
    test "has all 18 guides" do
      # 4 getting-started + 4 developer + 3 non-developer + 2 best-practices + 5 metrics = 18
      assert length(HowToData.all_how_tos()) == 18
    end
  end
end
