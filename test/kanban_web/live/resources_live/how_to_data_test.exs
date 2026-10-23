defmodule KanbanWeb.ResourcesLive.HowToDataTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.ResourcesLive.HowToData

  @getting_started_ids [
    "creating-your-first-board",
    "understanding-columns",
    "adding-your-first-task",
    "inviting-team-members",
    "using-stride-with-a-team"
  ]

  @working_with_tasks_ids [
    "writing-tasks-for-ai",
    "monitoring-task-progress",
    "reviewing-completed-work",
    "organizing-with-dependencies",
    "using-complexity-priority"
  ]

  @developer_ids [
    "setting-up-hooks",
    "api-authentication",
    "claim-complete-workflow",
    "debugging-hooks"
  ]

  @hook_names ~w(before_doing after_doing before_review after_review after_goal)

  # Column names are board data, not translated strings, so they are checked
  # against the AI board's column list instead.
  @ai_board_columns ~w(Backlog Ready Doing Review Done)

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

    # The renderer escapes HTML, so raw markup in a guide reaches readers as
    # literal text. Name UI elements in words instead.
    test "no guide step contains raw HTML" do
      for how_to <- HowToData.all_how_tos(), step <- how_to.steps do
        refute step.content =~ ~r{</?[a-zA-Z!]},
               "#{how_to.id} step \"#{step.title}\" contains raw HTML"

        refute step.title =~ ~r{</?[a-zA-Z!]},
               "#{how_to.id} step \"#{step.title}\" has raw HTML in its title"
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

    test "the Open the Task Form step names the add button by its real label" do
      {:ok, guide} = HowToData.get_how_to("adding-your-first-task")
      step = Enum.find(guide.steps, &(&1.title == "Open the Task Form"))

      assert step.content =~ "**Add Task**"
      refute step.content =~ "keyboard shortcut"
      assert File.read!("lib/kanban_web/components/column_header.ex") =~ ~s{gettext("Add Task")}
    end

    test "every bolded UI label in the getting-started guides exists in the source" do
      sources =
        Enum.map_join(
          [
            "lib/kanban_web/components/side_nav.ex",
            "lib/kanban_web/components/board_tabs.ex",
            "lib/kanban_web/components/column_header.ex"
            | Path.wildcard("lib/kanban_web/live/{board,column,task}_live/**/*.{ex,heex}")
          ],
          &File.read!/1
        )

      labels =
        for id <- @getting_started_ids,
            {:ok, guide} = HowToData.get_how_to(id),
            step <- guide.steps,
            [_, label] <- Regex.scan(~r/\*\*([^*]+)\*\*/, step.content),
            do: {id, label}

      assert labels != []

      for {id, label} <- labels do
        assert sources =~ ~s("#{label}"), "#{id} names **#{label}**, which no screen shows"
      end
    end

    test "getting-started guides keep their ids and minimum step counts" do
      for {id, steps} <- [
            {"creating-your-first-board", 4},
            {"understanding-columns", 5},
            {"adding-your-first-task", 4},
            {"inviting-team-members", 5},
            {"using-stride-with-a-team", 7}
          ] do
        assert {:ok, guide} = HowToData.get_how_to(id)
        assert length(guide.steps) >= steps, "#{id} should have at least #{steps} steps"
      end
    end

    test "getting-started guides drop the labels the UI no longer shows" do
      content =
        for id <- @getting_started_ids,
            {:ok, guide} = HowToData.get_how_to(id),
            step <- guide.steps,
            into: "",
            do: step.content <> "\n"

      for stale <- [
            "My Boards",
            "Edit Board",
            "Edit board",
            "Board Users",
            "Can View",
            "Add User",
            "Create Task",
            "Add Column",
            "**None**",
            "must already have a Stride account"
          ] do
        refute content =~ stale, "a getting-started guide still says #{inspect(stale)}"
      end
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

      assert length(best_practices_guides) == 8

      guide_ids = Enum.map(best_practices_guides, & &1.id)
      assert "using-stride-with-a-team" in guide_ids
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

  describe "working-with-tasks guides" do
    defp working_with_tasks_content(ids \\ @working_with_tasks_ids) do
      for id <- ids,
          {:ok, guide} = HowToData.get_how_to(id),
          step <- guide.steps,
          into: "",
          do: step.content <> "\n"
    end

    test "every bolded UI label in the working-with-tasks guides exists in the source" do
      sources =
        Enum.map_join(
          [
            "lib/kanban_web/components/side_nav.ex",
            "lib/kanban_web/components/board_filter_bar.ex",
            "lib/kanban_web/components/keyboard_shortcuts_help.ex",
            "lib/kanban_web/components/task_card.ex",
            "lib/kanban_web/live/review_live.ex",
            "lib/kanban_web/live/review_live.html.heex",
            "lib/kanban_web/notification_labels.ex"
            | Path.wildcard("lib/kanban_web/components/review_*.ex") ++
                Path.wildcard("lib/kanban_web/live/{board,task}_live/**/*.{ex,heex}")
          ],
          &File.read!/1
        )

      columns = File.read!("lib/kanban/boards/creation.ex")

      labels =
        for id <- @working_with_tasks_ids,
            {:ok, guide} = HowToData.get_how_to(id),
            step <- guide.steps,
            [_, label] <- Regex.scan(~r/\*\*([^*]+)\*\*/, step.content),
            do: {id, label}

      for id <- @working_with_tasks_ids do
        assert Enum.any?(labels, &(elem(&1, 0) == id)), "#{id} bolds no UI label"
      end

      for {id, label} <- labels do
        # A bare quoted string would also match an attribute or a map key, so
        # a label must be the text of a gettext call.
        translated = ~r/gettext\("#{Regex.escape(label)}"/

        assert sources =~ translated or
                 (label in @ai_board_columns and columns =~ ~s(name: "#{label}")),
               "#{id} names **#{label}**, which no screen shows"
      end
    end

    test "working-with-tasks guides keep their ids, titles and minimum step counts" do
      for {id, title, steps} <- [
            {"writing-tasks-for-ai", "Writing Effective Tasks for AI Agents", 6},
            {"monitoring-task-progress", "Monitoring Task Progress", 5},
            {"reviewing-completed-work", "Reviewing Completed Work", 6},
            {"organizing-with-dependencies", "Organizing Tasks with Dependencies", 5},
            {"using-complexity-priority", "Using Complexity and Priority Effectively", 5}
          ] do
        assert {:ok, guide} = HowToData.get_how_to(id)
        assert guide.title == title
        assert length(guide.steps) >= steps, "#{id} should have at least #{steps} steps"
      end
    end

    test "working-with-tasks guides drop the claims the app no longer makes" do
      content = working_with_tasks_content()

      for stale <- [
            "Request Changes",
            "Dependencies** field",
            "Select tasks that must complete first",
            "Filter by status",
            "returns to Ready",
            "Optionally add review notes",
            "after_review",
            "which agent claimed it and when",
            "under 2 hours",
            "2-8 hours",
            "8+ hours",
            "**Good examples:**",
            "**Priority levels:**",
            "so you can tick them off",
            "Only the board owner sees",
            "for another row"
          ] do
        refute content =~ stale, "a working-with-tasks guide still says #{inspect(stale)}"
      end
    end

    test "the claim, filter, review and sizing facts match the code" do
      monitoring = working_with_tasks_content(["monitoring-task-progress"])
      assert monitoring =~ "A claim lasts 60 minutes"
      assert monitoring =~ "the task stays in **Doing**"
      assert File.read!("lib/kanban/tasks/agent_workflow.ex") =~ "DateTime.add(60 * 60, :second)"
      assert File.read!("lib/kanban/notifications/claim_expiry_worker.ex") =~ "never unclaims"

      assert monitoring =~ "no status filter"
      refute Map.has_key?(%Kanban.Tasks.BoardFilters{}, :status)

      reviewing = working_with_tasks_content(["reviewing-completed-work"])
      header = File.read!("lib/kanban_web/components/review_detail_header.ex")

      for label <- ["Approve", "Request changes"] do
        assert reviewing =~ "Click **#{label}**"
        assert header =~ ~s{gettext("#{label}")}
      end

      caveat = "When Stride's plans are switched on, a free board sends no notifications."
      assert monitoring =~ caveat
      assert reviewing =~ caveat
      assert File.read!("lib/kanban/notifications.ex") =~ "Kanban.Plans.board_unlocked?/1"

      sizing = working_with_tasks_content(["using-complexity-priority"])
      assert sizing =~ "under 1 hour"
      assert sizing =~ "1 to 2 hours"
      assert sizing =~ "more than 2 hours"

      assert File.read!("docs/TASK-WRITING-GUIDE.md") =~
               "Small (< 1 hour), Medium (1-2 hours), Large (> 2 hours)"
    end
  end

  describe "developer guides" do
    defp developer_content(ids) do
      for id <- ids,
          {:ok, guide} = HowToData.get_how_to(id),
          step <- guide.steps,
          into: "",
          do: step.content <> "\n"
    end

    test "every bolded UI label in the developer guides exists in the source" do
      sources =
        Enum.map_join(
          [
            "lib/kanban_web/components/board_tabs.ex",
            "lib/kanban_web/components/side_nav.ex",
            "lib/kanban_web/components/workspace_switcher.ex"
            | Path.wildcard("lib/kanban_web/components/review_*.ex") ++
                Path.wildcard("lib/kanban_web/live/workspace_live/**/*.{ex,heex}") ++
                Path.wildcard("lib/kanban_web/live/{board,task}_live/**/*.{ex,heex}")
          ],
          &File.read!/1
        )

      columns = File.read!("lib/kanban/boards/creation.ex")

      labels =
        for id <- @developer_ids,
            {:ok, guide} = HowToData.get_how_to(id),
            step <- guide.steps,
            [_, label] <- Regex.scan(~r/\*\*([^*]+)\*\*/, step.content),
            do: {id, label}

      for id <- @developer_ids do
        assert Enum.any?(labels, &(elem(&1, 0) == id)), "#{id} bolds no UI label"
      end

      for {id, label} <- labels do
        # Hook names, API fields and statuses belong in inline code.
        refute label =~ ~r/^[a-z_]+$/, "#{id} bolds #{label}, which is code, not a UI label"

        translated = ~r/gettext\("#{Regex.escape(label)}"/

        assert sources =~ translated or
                 (label in @ai_board_columns and columns =~ ~s(name: "#{label}")),
               "#{id} names **#{label}**, which no screen shows"
      end
    end

    test "developer guides keep their ids, titles and minimum step counts" do
      for {id, title, steps} <- [
            {"setting-up-hooks", "Setting Up Hook Execution", 6},
            {"api-authentication", "Configuring API Authentication", 6},
            {"claim-complete-workflow", "Understanding Claim/Complete Workflow", 10},
            {"debugging-hooks", "Debugging Hook Failures", 5}
          ] do
        assert {:ok, guide} = HowToData.get_how_to(id)
        assert guide.title == title
        assert length(guide.steps) >= steps, "#{id} should have at least #{steps} steps"
      end
    end

    test "developer guides drop the claims the server no longer makes" do
      content = developer_content(@developer_ids)

      for stale <- [
            "four hooks",
            "60s timeout",
            "120s timeout",
            "60-120s",
            "under 60 seconds",
            "In Progress",
            "source .stride.md",
            "The API returns hook output",
            "board settings",
            "Generate Token",
            "**API Tokens**",
            "Rotate tokens periodically",
            "60-second grace",
            "do not execute for regular boards",
            "notified of approval",
            "**CRITICAL:**",
            "**Important:**",
            "**Remember:**",
            "1. **Open**",
            "Local User Email",
            "the next `hook`",
            "The responses say which hooks come next"
          ] do
        refute content =~ stale, "a developer guide still says #{inspect(stale)}"
      end
    end

    test "the hook facts match the server" do
      hooks = developer_content(["setting-up-hooks"])
      server = File.read!("lib/kanban/hooks.ex")

      for name <- @hook_names do
        assert server =~ ~s("#{name}" => %{blocking: true, timeout: 600_000}),
               "#{name} is no longer blocking with a 600 s timeout"

        assert hooks =~ "`#{name}`"
      end

      assert hooks =~ "All five hooks are sent as blocking, with a timeout of 600 seconds"
      assert hooks =~ "Stride's server never runs them"
      assert server =~ "The server does NOT execute hooks"

      environment = File.read!("lib/kanban/hooks/environment.ex")

      for var <-
            ~w(TASK_ID TASK_IDENTIFIER TASK_TITLE TASK_DESCRIPTION TASK_STATUS TASK_COMPLEXITY
               TASK_PRIORITY TASK_NEEDS_REVIEW BOARD_ID BOARD_NAME COLUMN_ID COLUMN_NAME
               AGENT_NAME HOOK_NAME) do
        assert environment =~ ~s("#{var}" =>), "the server no longer sends #{var}"
        assert hooks =~ "`#{var}`", "the hooks guide doesn't list #{var}"
      end

      metadata = File.read!("lib/kanban/hooks/metadata.ex")
      assert metadata =~ "[after_doing, before_review, after_review]"
      assert hooks =~ "plus `after_review` when `needs_review` is false"

      assert File.read!("lib/kanban/tasks/agent_workflow.ex") =~
               ~s|Hooks.get_hook_info(updated_task, board, "before_doing", agent_name)|

      assert hooks =~
               "The claim response's `hook` is the `before_doing` hook the agent has just run"

      assert metadata =~ "def build_mark_reviewed_hooks"
      assert hooks =~ "or the `mark_reviewed` call that approves it"

      assert File.read!("config/config.exs") =~
               "config :kanban, :after_goal_grace_window_ms, 300_000"

      assert hooks =~ "five-minute grace window"
      assert File.read!("lib/kanban_web/router.ex") =~ ~s(patch "/tasks/:id/after_goal")
    end

    test "the claim and complete facts match the server" do
      workflow = developer_content(["claim-complete-workflow"])
      agent_workflow = File.read!("lib/kanban/tasks/agent_workflow.ex")

      assert workflow =~ "A claim lasts 60 minutes"
      assert agent_workflow =~ "DateTime.add(60 * 60, :second)"
      assert workflow =~ "moves it to **Doing**"
      assert agent_workflow =~ ~s{get_column_by_name(board_id, "Doing")}
      assert File.read!("lib/kanban/notifications/claim_expiry_worker.ex") =~ "never unclaims"

      assert File.read!("lib/kanban/tasks/agent_queries.ex") =~
               "t.status == :open or (t.status == :in_progress and t.claim_expires_at < ^now)"

      assert workflow =~ "Status `open`, or `in_progress` with a claim that has run out"

      assert File.read!("lib/kanban_web/router.ex") =~ ~s(post "/tasks/:id/unclaim")
      assert workflow =~ "`POST /api/tasks/:id/unclaim`"

      for field <-
            ~w(completion_summary actual_complexity actual_files_changed time_spent_minutes) do
        assert agent_workflow =~ ~r/validate_required\(\[[^\]]*:#{field}/,
               "complete no longer requires #{field}"

        assert workflow =~ "`#{field}`"
      end

      for status <- Ecto.Enum.values(Kanban.Tasks.Task, :status) do
        assert workflow =~ "`#{status}`", "the workflow guide doesn't name the #{status} status"
      end

      header = File.read!("lib/kanban_web/components/review_detail_header.ex")

      for label <- ["Approve", "Request changes"] do
        assert workflow =~ "**#{label}**"
        assert header =~ ~s{gettext("#{label}")}
      end
    end

    test "the token and debugging facts match the code" do
      auth = developer_content(["api-authentication"])

      assert File.read!("lib/kanban_web/components/board_tabs.ex") =~
               "hidden?(:tokens, flags), do: not (flags.modify? and flags.ai_optimized?)"

      assert auth =~ "click the **Tokens** tab; only the owner and members with edit access"
      assert File.read!("lib/kanban/api_tokens/api_token.ex") =~ "@default_token_lifetime_days 90"
      assert auth =~ "Tokens expire 90 days after they are created"
      assert File.read!("lib/kanban_web/plugs/authenticate_api_token.ex") =~ "X-Stride-Board"
      assert auth =~ "`X-Stride-Board`"

      debugging = developer_content(["debugging-hooks"])

      assert File.read!("lib/kanban/hooks/validator.ex") =~
               ~S"is a blocking hook and failed with exit code #{code}. Fix the issues and try again."

      assert debugging =~
               "after_doing is a blocking hook and failed with exit code 1. Fix the issues and try again."

      assert debugging =~ "you can't source it"
      assert debugging =~ "one at a time"
      assert File.read!("docs/AGENT-HOOK-EXECUTION-GUIDE.md") =~ "one at a time"
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
    test "has all 20 guides" do
      assert length(HowToData.all_how_tos()) == 20
    end

    test "every guide id is unique across the area modules" do
      ids = Enum.map(HowToData.all_how_tos(), & &1.id)
      assert ids == Enum.uniq(ids)
    end
  end

  describe "two-factor authentication guide" do
    test "is a beginner security guide with steps" do
      assert {:ok, guide} = HowToData.get_how_to("two-factor-authentication")
      assert guide.tags == ["security", "beginner"]
      assert guide.created_at == ~D[2026-10-08]
      assert length(guide.steps) >= 10
    end

    test "sits next to the API authentication guide in security navigation" do
      {:ok, guide} = HowToData.get_how_to("two-factor-authentication")

      assert {nil, %{id: "api-authentication"}} = HowToData.get_navigation(guide)
    end

    test "every bolded UI label it names still exists in the two-factor screens" do
      sources =
        Enum.map_join(
          [
            "lib/kanban_web/live/user_live/two_factor_component.ex",
            "lib/kanban_web/live/user_live/two_factor.ex",
            "lib/kanban_web/live/user_live/login.ex",
            "lib/kanban_web/live/user_live/settings.ex",
            "lib/kanban_web/live/user_live/settings_components.ex",
            "lib/kanban_web/components/layouts.ex",
            "lib/kanban_web/components/two_factor_reminder.ex"
          ],
          &File.read!/1
        )

      {:ok, guide} = HowToData.get_how_to("two-factor-authentication")

      labels =
        for step <- guide.steps,
            [_, label] <- Regex.scan(~r/\*\*([^*]+)\*\*/, step.content),
            label not in ["and", "An authenticator app", "A safe place for ten recovery codes"],
            not String.ends_with?(label, "."),
            not String.ends_with?(label, "?"),
            do: String.replace(label, "Settings → Two-factor", "Two-factor")

      assert labels != []

      for label <- labels do
        assert sources =~ ~s("#{label}"), "the guide names **#{label}**, which no screen shows"
      end
    end
  end

  describe "type_icons/0" do
    test "returns the content-type to icon mapping" do
      icons = HowToData.type_icons()

      assert is_map(icons)
      assert Map.has_key?(icons, "guide")
      assert Map.has_key?(icons, "tutorial")
      assert Map.has_key?(icons, "reference")
      assert Map.has_key?(icons, "video")
    end

    test "icon values match what type_icon/1 returns for each content type" do
      icons = HowToData.type_icons()

      for {content_type, icon} <- icons do
        assert HowToData.type_icon(content_type) == icon
      end
    end
  end

  describe "get_navigation/1 edge cases" do
    test "returns {nil, nil} when current_how_to has no tags" do
      orphan = %{id: "no-tags", tags: []}

      assert HowToData.get_navigation(orphan) == {nil, nil}
    end

    test "returns {nil, nil} when current_how_to's primary tag matches no guides" do
      orphan = %{id: "isolated", tags: ["this-tag-does-not-exist-anywhere"]}

      assert HowToData.get_navigation(orphan) == {nil, nil}
    end

    test "returns nil for next when at the end of the related list" do
      # Walk the developer tag list to find the last guide, then assert that
      # get_navigation returns nil for `next` on that last guide. This exercises
      # the neighbor_at clause where target_index is out-of-bounds on the right.
      developer_guides =
        HowToData.all_how_tos()
        |> Enum.filter(&("developer" in &1.tags))

      last_developer_guide = List.last(developer_guides)
      {_prev, next} = HowToData.get_navigation(last_developer_guide)

      assert next == nil
    end
  end
end
