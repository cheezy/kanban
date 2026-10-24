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

  @metrics_ids [
    "metrics-dashboard",
    "throughput-metrics",
    "cycle-time-metrics",
    "lead-time-metrics",
    "wait-time-metrics",
    "workspace-and-compliance-metrics"
  ]

  @account_ids ["managing-your-account", "two-factor-authentication"]

  # The account screens whose gettext strings the account guides may bold.
  @account_sources [
    "lib/kanban_web/live/user_live/two_factor_component.ex",
    "lib/kanban_web/live/user_live/two_factor.ex",
    "lib/kanban_web/live/user_live/login.ex",
    "lib/kanban_web/live/user_live/settings.ex",
    "lib/kanban_web/live/user_live/settings_components.ex",
    "lib/kanban_web/components/layouts.ex",
    "lib/kanban_web/components/two_factor_reminder.ex",
    "lib/kanban_web/live/user_live/danger_zone_component.ex",
    "lib/kanban_web/components/organization_two_factor_banner.ex"
  ]

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
    test "all 9 best-practices guides exist" do
      best_practices_guides =
        HowToData.all_how_tos()
        |> Enum.filter(&("best-practices" in &1.tags))

      assert length(best_practices_guides) == 9

      guide_ids = Enum.map(best_practices_guides, & &1.id)
      assert "using-stride-with-a-team" in guide_ids
      assert "organizing-with-dependencies" in guide_ids
      assert "using-complexity-priority" in guide_ids
      assert "metrics-dashboard" in guide_ids
      assert "throughput-metrics" in guide_ids
      assert "cycle-time-metrics" in guide_ids
      assert "lead-time-metrics" in guide_ids
      assert "wait-time-metrics" in guide_ids
      assert "workspace-and-compliance-metrics" in guide_ids
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

  describe "metrics guides" do
    defp metrics_content(ids) do
      for id <- ids,
          {:ok, guide} = HowToData.get_how_to(id),
          step <- guide.steps,
          into: "",
          do: step.content <> "\n"
    end

    test "every bolded UI label in the metrics guides exists in the source" do
      sources =
        Enum.map_join(
          [
            "lib/kanban_web/components/board_tabs.ex",
            "lib/kanban_web/components/side_nav.ex"
            | Path.wildcard("lib/kanban_web/live/metrics_live/**/*.{ex,heex}") ++
                Path.wildcard("lib/kanban_web/components/metrics_*.ex")
          ],
          &File.read!/1
        )

      labels =
        for id <- @metrics_ids,
            {:ok, guide} = HowToData.get_how_to(id),
            step <- guide.steps,
            [_, label] <- Regex.scan(~r/\*\*([^*]+)\*\*/, step.content),
            do: {id, label}

      for id <- @metrics_ids do
        assert Enum.any?(labels, &(elem(&1, 0) == id)), "#{id} bolds no UI label"
      end

      for {id, label} <- labels do
        refute label =~ ~r/^[a-z_]+$/, "#{id} bolds #{label}, which is code, not a UI label"

        assert sources =~ ~r/gettext\("#{Regex.escape(label)}"/,
               "#{id} names **#{label}**, which no metrics screen shows"
      end
    end

    test "metrics guides keep their ids and minimum step counts" do
      for {id, title, steps} <- [
            {"metrics-dashboard", "Using the Metrics Dashboard", 4},
            {"throughput-metrics", "Tracking Throughput", 4},
            {"cycle-time-metrics", "Understanding Cycle Time", 4},
            {"lead-time-metrics", "Understanding Lead Time", 4},
            {"wait-time-metrics", "Understanding Wait Time", 4},
            {"workspace-and-compliance-metrics", "Workspace Metrics and Compliance", 9}
          ] do
        assert {:ok, guide} = HowToData.get_how_to(id)
        assert guide.title == title
        assert length(guide.steps) >= steps, "#{id} should have at least #{steps} steps"
      end

      # Navigation groups guides by first tag: the old five stay in the
      # best-practices group, and the new guide leads a metrics group.
      for id <- Enum.take(@metrics_ids, 5) do
        {:ok, guide} = HowToData.get_how_to(id)
        assert guide.tags == ["best-practices", "metrics", "monitoring"]
      end

      {:ok, new_guide} = HowToData.get_how_to("workspace-and-compliance-metrics")
      assert new_guide.tags == ["metrics", "best-practices", "monitoring"]
      assert {%{id: "wait-time-metrics"}, nil} = HowToData.get_navigation(new_guide)

      {:ok, wait_time} = HowToData.get_how_to("wait-time-metrics")

      assert {_previous, %{id: "workspace-and-compliance-metrics"}} =
               HowToData.get_navigation(wait_time)
    end

    test "metrics guides drop the claims the app no longer makes" do
      content = metrics_content(@metrics_ids)

      for stale <- [
            "Metrics →",
            "**Agent**:",
            "Review time",
            "Upward trends",
            "Flat lines",
            "**Dips**",
            "**Trends**",
            "remove weekend data",
            "task complexity and actual cycle time",
            "**Backlog Wait**",
            "**Review Wait**",
            "in the navigation",
            "**idle**",
            "Speed up reviews",
            "Use notifications",
            "amber"
          ] do
        refute content =~ stale, "a metrics guide still says #{inspect(stale)}"
      end

      titles =
        for id <- @metrics_ids,
            {:ok, guide} = HowToData.get_how_to(id),
            step <- guide.steps,
            do: step.title

      refute "Reading the Tables" in titles
    end

    test "the board metrics facts match the code" do
      dashboard = metrics_content(["metrics-dashboard"])
      live = "lib/kanban_web/live/metrics_live/"

      assert File.read!(live <> "base.ex") =~ "time_range: :last_30_days"
      assert dashboard =~ "The range starts at **Last 30 Days**"

      for page <- ~w(dashboard throughput cycle_time lead_time wait_time) do
        assert File.read!(live <> page <> ".html.heex") =~
                 "show_agent_filter={@board.ai_optimized_board}"
      end

      assert dashboard =~ "**Agent Filter** appears only on AI-optimized boards"

      assert File.read!("lib/kanban/metrics.ex") =~
               "t.completed_by_agent == ^agent_name or t.created_by_agent == ^agent_name"

      assert dashboard =~ "only the tasks it completed or created"
      assert File.read!("lib/kanban/metrics.ex") =~ "maybe_filter_by_completing_agent(agent_name)"
      assert dashboard =~ "(for wait time, only the tasks it completed)"

      # The detail pages pass the browser time zone; the dashboard passes none,
      # so Kanban.Metrics falls back to UTC for its cards.
      assert File.read!(live <> "base.ex") =~
               "timezone: KanbanWeb.Timezone.browser_timezone(socket)"

      refute File.read!(live <> "dashboard.ex") =~ "timezone"
      assert dashboard =~ "The dashboard's cards count from midnight UTC"

      # Board metrics and their exports aren't plan-gated, so no guide may say so.
      metrics_code =
        Enum.map_join(
          Path.wildcard(live <> "**/*.{ex,heex}") ++
            [
              "lib/kanban_web/controllers/metrics_pdf_controller.ex",
              "lib/kanban_web/controllers/workspace_metrics_export_controller.ex"
            ],
          &File.read!/1
        )

      refute metrics_code =~ "Plans."
      refute metrics_code =~ "plans_enforced"
      all_guides = metrics_content(@metrics_ids)

      for lock <- ["locked", "paid plan", "upgrade", "Upgrade", "free board"] do
        refute all_guides =~ lock, "a metrics guide claims a plan lock: #{inspect(lock)}"
      end

      router = File.read!("lib/kanban_web/router.ex")
      assert router =~ ~s(get "/boards/:id/metrics/:metric/export", MetricsPdfController, :export)
      assert router =~ ~s(get "/metrics/export", WorkspaceMetricsExportController, :export)

      exports = File.read!("lib/kanban_web/controllers/metrics_pdf_controller.ex")

      for metric <- ~w(throughput cycle-time lead-time wait-time) do
        assert exports =~ ~s("#{metric}" =>)
        page = String.replace(metric, "-", "_")
        assert File.read!(live <> page <> ".html.heex") =~ "<.export_dropdown"
      end

      refute exports =~ ~s("compliance" =>)

      for page <- ~w(dashboard compliance) do
        refute File.read!(live <> page <> ".html.heex") =~ "export_dropdown"
      end

      assert dashboard =~ "The dashboard and the Compliance page have no export"

      metrics = File.read!("lib/kanban/metrics.ex")
      assert metrics =~ "Cycle time is measured from `claimed_at` to `completed_at`"
      assert metrics =~ "Lead time is measured from task creation (`inserted_at`)"
      assert metrics =~ "Review wait time - Time from `completed_at` to `reviewed_at`"

      lead = metrics_content(["lead-time-metrics"])
      assert lead =~ "Lead time = backlog wait + cycle time"
      assert lead =~ "Review wait starts when the agent completes the task"

      assert File.read!(live <> "throughput.ex") =~ "total / days_count"
      assert metrics_content(["throughput-metrics"]) =~ "divided by the days that had completions"
    end

    test "the workspace and compliance facts match the code" do
      guide = metrics_content(["workspace-and-compliance-metrics"])
      live = "lib/kanban_web/live/metrics_live/"

      helpers = File.read!(live <> "helpers.ex")
      assert helpers =~ "@window_options [7, 14, 30, 90]"
      assert helpers =~ "@default_window_days 14"
      assert guide =~ "the last 7, 14, 30 or 90 days. It starts at 14 days"

      assert File.read!("lib/kanban_web/controllers/workspace_metrics_export_controller.ex") =~
               ~S|"stride_workspace_metrics_#{assigns.window_days}d_#{date}#{extension}"|

      assert guide =~ "`stride_workspace_metrics_14d_"

      assert File.read!("lib/kanban/metrics/workspace.ex") =~
               "up to six contributors (agents before humans"

      assert guide =~ "ranks the top six contributors **by completed**, agents before people"

      assert File.read!("lib/kanban/metrics/workspace/completed_tasks.ex") =~
               "length(counted_current) / counted_days"

      assert guide =~ "**Throughput** is the average number of tasks completed per day"

      assert File.read!("lib/kanban/metrics/workspace/cumulative_flow.ex") =~
               "| `:ready`    | always 0"

      assert guide =~ "the Ready band stays empty"

      compliance = File.read!(live <> "compliance.ex")
      assert compliance =~ "true <- Boards.can_modify?(board, user)"

      assert File.read!("lib/kanban/boards.ex") =~
               "get_user_access(board_id, user.id) in [:owner, :modify]"

      assert guide =~ "Only the board's owner and members with edit access can open it"

      assert File.read!(live <> "dashboard.html.heex") =~
               ~r/:if=\{@board.ai_optimized_board\}\s*navigate=\{~p"\/boards\/#\{@board\}\/metrics\/compliance"\}/

      refute File.read!(live <> "compliance.html.heex") =~ "metrics-filter-form"
      assert guide =~ "The page has no filters and no export"

      assert compliance =~ ~s|when rate >= 80.0, do: "var(--st-done)"|
      assert compliance =~ ~s|when rate >= 50.0, do: "var(--st-review)"|
      assert compliance =~ ~s|dispatch_rate_color(_rate), do: "var(--st-blocked)"|

      assert guide =~
               "the Done column's colour at 80% or more, the Review column's colour from 50%, and red below 50%"

      for code <- Kanban.Tasks.WorkflowSteps.skip_reason_codes() do
        [_, label] =
          Regex.run(~r/skip_reason_label\("#{code}"\), do: gettext\("([^"]+)"\)/, compliance)

        assert guide =~ "**#{label}**", "the guide doesn't name the #{code} skip reason"
      end

      for name <- ~w(explorer planner implementation reviewer) do
        assert name in Kanban.Tasks.WorkflowSteps.canonical_step_names()
        assert guide =~ "`#{name}`"
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
    test "has all 22 guides" do
      assert length(HowToData.all_how_tos()) == 22
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
      assert length(guide.steps) >= 13
    end

    test "sits between the account guide and the API authentication guide in security navigation" do
      {:ok, guide} = HowToData.get_how_to("two-factor-authentication")

      assert {%{id: "managing-your-account"}, %{id: "api-authentication"}} =
               HowToData.get_navigation(guide)
    end

    test "every bolded UI label it names still exists in the two-factor screens" do
      sources = Enum.map_join(@account_sources, &File.read!/1)

      {:ok, guide} = HowToData.get_how_to("two-factor-authentication")

      labels =
        for step <- guide.steps,
            [_, label] <- Regex.scan(~r/\*\*([^*]+)\*\*/, step.content),
            do: String.replace(label, "Settings → Two-factor", "Two-factor")

      assert labels != []

      for label <- labels do
        assert sources =~ ~s("#{label}"), "the guide names **#{label}**, which no screen shows"
      end
    end
  end

  describe "account guides" do
    defp account_content(ids) do
      for id <- ids,
          {:ok, guide} = HowToData.get_how_to(id),
          step <- guide.steps,
          into: "",
          do: step.content <> "\n"
    end

    test "every bolded UI label in the account guides exists in the source" do
      sources = Enum.map_join(@account_sources, &File.read!/1)

      labels =
        for id <- @account_ids,
            {:ok, guide} = HowToData.get_how_to(id),
            step <- guide.steps,
            [_, bold] <- Regex.scan(~r/\*\*([^*]+)\*\*/, step.content),
            label <- String.split(bold, " → "),
            do: {id, label}

      for id <- @account_ids do
        assert Enum.any?(labels, &(elem(&1, 0) == id)), "#{id} bolds no UI label"
      end

      for {id, label} <- labels do
        refute label =~ ~r/^[a-z_]+$/, "#{id} bolds #{label}, which is code, not a UI label"

        assert sources =~ ~r/gettext\("#{Regex.escape(label)}"/,
               "#{id} names **#{label}**, which no account screen shows"
      end
    end

    test "account guides keep their ids and minimum step counts" do
      expected = [
        {"managing-your-account", "Managing Your Account", 8},
        {"two-factor-authentication", "Setting Up Two-Factor Authentication", 13}
      ]

      assert Enum.map(KanbanWeb.ResourcesLive.HowTos.Account.how_tos(), & &1.id) == @account_ids

      for {id, title, min_steps} <- expected do
        assert {:ok, guide} = HowToData.get_how_to(id)
        assert guide.title == title
        assert guide.tags == ["security", "beginner"]
        assert length(guide.steps) >= min_steps, "#{id} lost steps"
      end

      {:ok, account} = HowToData.get_how_to("managing-your-account")
      assert account.created_at == ~D[2026-10-23]

      assert {nil, %{id: "two-factor-authentication"}} = HowToData.get_navigation(account)
    end

    test "the two-factor guide drops the claims the app no longer makes" do
      content = account_content(["two-factor-authentication"])

      for stale <- [
            "Two-factor is optional and applies only to you",
            "If you have not signed in recently",
            "Save them now",
            "**and**",
            "**An authenticator app**",
            "**Check your device's clock.**"
          ] do
        refute content =~ stale, "the two-factor guide still says #{inspect(stale)}"
      end
    end

    test "the account settings facts match the code" do
      account = account_content(["managing-your-account"])
      user_auth = File.read!("lib/kanban_web/user_auth.ex")
      session = File.read!("lib/kanban_web/controllers/user_session_controller.ex")

      assert account =~ "within the last 10 minutes"
      assert user_auth =~ "Accounts.sudo_mode?(user, -10)"
      assert session =~ "Accounts.sudo_mode?(user, -10)"

      # The re-authentication flash is hard-coded English, so it is quoted, never bolded.
      assert account =~ ~s("You must re-authenticate to access this page.")
      assert user_auth =~ ~s(put_flash(:error, "You must re-authenticate to access this page."\))
      assert account =~ "Stride takes you to Settings"

      assert user_auth =~
               ~r/def signed_in_path\(%Plug.Conn\{assigns: %\{current_scope: %Scope\{user: %Accounts.User\{\}\}\}\}\) do\s+~p"\/users\/settings"/

      tabs =
        Regex.scan(
          ~r/gettext\("([^"]+)"\), gettext\("[^"]+"\)\}/,
          File.read!("lib/kanban_web/live/user_live/settings_components.ex"),
          capture: :all_but_first
        )
        |> List.flatten()

      assert tabs == ["Profile", "Password", "Two-factor", "Single sign-on", "Delete account"]
      assert account =~ "Settings has five tabs"

      assert Enum.map(tabs, &"- **#{&1}**") ==
               Regex.scan(~r/^- \*\*[^*]+\*\*/m, account) |> List.flatten() |> Enum.take(5)

      assert account =~ "[Notification preferences](/users/notifications)"

      assert File.read!("lib/kanban_web/router.ex") =~
               ~s(live "/users/notifications", UserLive.NotificationPreferences)

      assert account =~ "The link works for 7 days"
      assert account =~ "your email changes only when you click that link"
      assert File.read!("lib/kanban/accounts/user_token.ex") =~ "@change_email_validity_in_days 7"

      user = File.read!("lib/kanban/accounts/user.ex")
      assert account =~ "12 to 72 characters long"
      assert account =~ "The 72 counts bytes"
      assert user =~ "validate_length(:password, min: 12, max: 72)"
      assert user =~ "validate_length(:password, max: 72, count: :bytes)"

      assert account =~ "signs you out on every other device"
      assert session =~ "UserAuth.disconnect_sessions(expired_tokens)"
      assert File.read!("lib/kanban/accounts.ex") =~ "|> update_user_and_delete_all_tokens()"

      assert account =~ "an account that does not belong to an Organization sees a lock"

      assert File.read!("lib/kanban_web/live/user_live/settings.ex") =~
               "not Plans.user_unlocked?(socket.assigns.current_scope)"

      assert File.read!("lib/kanban/plans.ex") =~
               "def user_has_paid_access?(%Scope{organization_membership: %OrganizationMember{}}), do: true"
    end

    test "the account deletion facts match the code" do
      account = account_content(["managing-your-account"])
      danger = File.read!("lib/kanban_web/live/user_live/danger_zone_component.ex")

      assert account =~ "type `delete my account` exactly as shown"
      assert Kanban.Accounts.AccountDeletion.confirmation_phrase() == "delete my account"

      for blocker <- [
            "You own %{board}, which other people use.",
            "A Stride admin must appoint another org-admin before you can delete your account.",
            "You are the last site admin. Make another user a site admin before you delete your account."
          ] do
        assert danger =~ ~r/gettext\(\s*"#{Regex.escape(blocker)}"/
      end

      assert account =~ "A Stride admin must appoint another org-admin first"
      assert account =~ "Make another user a site admin first"

      assert account =~ "The **Delete my account** button appears only once that list is empty"
      assert danger =~ "<div :if={@blockers == []}>"

      assert account =~ "After a few wrong passwords, Stride makes you wait a few minutes"

      assert File.read!("lib/kanban/rate_limit.ex") =~
               "account_delete: %{scale_ms: 300_000, id_limit: 5}"

      assert account =~ "Use **Forgot?** on the sign-in page to set one first"

      assert File.read!("docs/single-sign-on.md") =~
               "An account created by single sign-on starts without a password"
    end

    test "the two-factor facts match the code" do
      two_factor = account_content(["two-factor-authentication"])
      accounts_two_factor = File.read!("lib/kanban/accounts/two_factor.ex")

      assert two_factor =~ "within the last 10 minutes"
      assert two_factor =~ "**Not now** hides the card for 10 days"
      assert accounts_two_factor =~ "@reminder_snooze_days 10"

      assert two_factor =~
               "The card does not appear while your Organization's two-factor banner is showing"

      assert File.read!("lib/kanban_web/components/layouts.ex") =~
               ":if={!(@current_scope && @current_scope.two_factor_deadline)}"

      assert two_factor =~ "Enter it within five minutes"
      assert KanbanWeb.TwoFactorPending.ttl_seconds() == 300

      assert two_factor =~ "about a minute and a half"
      assert accounts_two_factor =~ "@period 30"
      assert accounts_two_factor =~ "@drift_steps [0, -1, 1]"

      assert two_factor =~ "ten recovery codes"
      assert accounts_two_factor =~ "@recovery_code_count 10"

      rate_limit = File.read!("lib/kanban/rate_limit.ex")
      assert two_factor =~ "a few minutes at first, and up to a day"
      assert rate_limit =~ "two_factor: %{scale_ms: 300_000, id_limit: 10}"
      assert rate_limit =~ "two_factor_daily: %{scale_ms: 86_400_000, id_limit: 30}"

      assert two_factor =~ "from 1 to 30 days (7 unless they change it)"
      assert Kanban.Organizations.SecurityPolicy.grace_days_range() == 1..30
      assert %Kanban.Organizations.SecurityPolicy{}.two_factor_grace_days == 7

      assert two_factor =~
               "opening a board or any other signed-in page sends you to **Settings → Two-factor**"

      refute two_factor =~ "from every other page"

      assert File.read!("lib/kanban_web/user_auth/organization_two_factor_gate.ex") =~
               "public pages, and every `/api` route"

      assert KanbanWeb.UserAuth.OrganizationTwoFactorGate.redirect_path() ==
               "/users/settings?section=two_factor"

      assert two_factor =~ "While it is required, you cannot turn two-factor off"
      assert two_factor =~ "the **Turn off two-factor** section says so and has no button"
      refute two_factor =~ "**Turn off two-factor** is not shown"

      component = File.read!("lib/kanban_web/live/user_live/two_factor_component.ex")
      assert component =~ ~s(id="two-factor-required-by-organization")
      assert component =~ ":if={!@required_by_organization}"
      assert accounts_two_factor =~ "do: {:error, :required_by_organization}"

      assert two_factor =~ "the banner cannot be dismissed"

      assert File.read!("lib/kanban_web/components/organization_two_factor_banner.ex") =~
               "it cannot be dismissed"

      assert two_factor =~ "satisfies the requirement"

      assert File.read!("lib/kanban_web/live/org_live/security.html.heex") =~
               "Members who sign in through single sign-on are not affected."

      # Only the two-factor context touches the secrets table, so no admin
      # screen can reset someone's two-factor.
      assert two_factor =~ "Stride cannot turn off two-factor for you"

      assert Path.wildcard("lib/**/*.{ex,heex}")
             |> Enum.filter(&(File.read!(&1) =~ ~r/UserTotp|user_totps/))
             |> Enum.sort() == [
               "lib/kanban/accounts/two_factor.ex",
               "lib/kanban/accounts/user_totp.ex"
             ]

      # New recovery codes take an authenticator code only, so an org-required
      # member without an authenticator is left with their saved codes.
      assert two_factor =~ "**Generate new codes** needs a code from your authenticator"
      assert accounts_two_factor =~ ":ok <- use_code(totp, code) do"
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
