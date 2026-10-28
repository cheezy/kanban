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

  @organization_ids ["free-and-paid-boards", "working-in-a-workspace", "accepting-an-invitation"]

  @org_admin_ids [
    "administering-your-organization",
    "reading-the-organization-audit-log",
    "organization-security-policy",
    "setting-up-single-sign-on",
    "provisioning-users-with-scim"
  ]

  @boards_ids [
    "managing-board-settings",
    "finding-work-with-search-and-filters",
    "bulk-editing-cards",
    "archiving-tasks"
  ]

  @agents_and_planning_ids [
    "watching-your-agents",
    "your-work-across-boards",
    "planning-with-targets"
  ]

  # The Agents page, My Work, target and goal screens. The `**` reaches
  # agents_live/components/, where the intervention dialogs live.
  @agents_and_planning_sources [
                                 "lib/kanban_web/components/side_nav.ex",
                                 "lib/kanban_web/live/agents_live.ex",
                                 "lib/kanban_web/components/agents_header.ex",
                                 "lib/kanban_web/components/agent_activity_feed.ex",
                                 "lib/kanban_web/components/agent_detail_panel.ex",
                                 "lib/kanban_web/components/agent_roster_card.ex",
                                 "lib/kanban_web/components/delivery_health_band.ex",
                                 "lib/kanban_web/components/target_risk_explainer.ex",
                                 "lib/kanban_web/live/my_work_live.ex",
                                 "lib/kanban_web/live/board_live/index.html.heex",
                                 "lib/kanban_web/components/targets_strip.ex",
                                 "lib/kanban_web/components/target_progress_header.ex",
                                 "lib/kanban_web/live/goal_live/show.ex",
                                 "lib/kanban_web/components/goal_sidebar.ex",
                                 "lib/kanban_web/components/goal_progress_header.ex",
                                 "lib/kanban_web/components/task_activity_log.ex"
                               ] ++
                                 Path.wildcard("lib/kanban_web/live/agents_live/**/*.ex") ++
                                 Path.wildcard("lib/kanban_web/live/target_live/*.{ex,heex}")

  @task_details_ids ["reading-a-tasks-details", "commenting-and-mentioning"]

  @notifications_integrations_ids [
    "staying-informed-with-notifications",
    "connecting-webhooks-slack-and-discord",
    "connecting-an-mcp-client"
  ]

  # Column names are board data, not translated strings, so a bolded column
  # name is also checked against the AI board's column list.
  @ai_board_columns ~w(Backlog Ready Doing Review Done)

  # Every screen a guide may name. The Resources pages are left out so the
  # guides' own page can't vouch for a label. Any screen can satisfy a label,
  # which is looser than a list per guide group, so a label that moves to
  # another screen still needs a human read.
  @label_sources "lib/kanban_web/**/*.{ex,heex}"
                 |> Path.wildcard()
                 |> Enum.reject(&String.starts_with?(&1, "lib/kanban_web/live/resources_live/"))

  # Labels the app shows as plain strings rather than through gettext. Keep
  # this short: each entry must still be a modal title in
  # @label_allow_list_source.
  @label_allow_list [
    # The task modal's titles, picked by @live_action in the board template.
    "New Task",
    "Edit Task"
  ]

  @label_allow_list_source "lib/kanban_web/live/board_live/show.html.heex"

  # Guides that name no UI label, and must keep naming none.
  @no_bold_guides [
    # Its steps are commands and config files, shown as code.
    "connecting-an-mcp-client"
  ]

  describe "every guide" do
    # A navigation path such as "Settings → Two-factor" names two labels.
    defp bold_labels(guide) do
      for step <- guide.steps,
          [_, bold] <- Regex.scan(~r/\*\*([^*]+)\*\*/, step.content),
          label <- String.split(bold, " → "),
          do: String.trim(label)
    end

    test "every bolded UI label in every guide exists in the app source" do
      sources = Enum.map_join(@label_sources, &File.read!/1)
      modal_titles = File.read!(@label_allow_list_source)
      columns = File.read!("lib/kanban/boards/creation.ex")

      for label <- @label_allow_list do
        assert modal_titles =~ ~s(-> "#{label}"),
               "**#{label}** is allow-listed but is no longer a task modal title"
      end

      for id <- @no_bold_guides do
        assert {:ok, guide} = HowToData.get_how_to(id)
        assert bold_labels(guide) == [], "#{id} is listed as bolding nothing, but bolds a label"
      end

      for guide <- HowToData.all_how_tos(), guide.id not in @no_bold_guides do
        assert bold_labels(guide) != [], "#{guide.id} bolds no UI label"
      end

      for guide <- HowToData.all_how_tos(),
          label <- bold_labels(guide),
          label not in @label_allow_list do
        refute label =~ ~r/^[a-z_.]+$/,
               "#{guide.id} bolds #{label}, which is code, not a UI label"

        # An aria-label is read out, not shown, so it can't be a bold label.
        assert sources =~ ~r/(?<!aria-label=\{)gettext\(\s*"#{Regex.escape(label)}"/,
               "#{guide.id} names **#{label}**, which no screen shows"

        # Other screens translate the column names too, so only the AI board's
        # own column list proves the column exists.
        if label in @ai_board_columns do
          assert columns =~ ~s(name: "#{label}"),
                 "#{guide.id} names the column **#{label}**, which the AI board doesn't have"
        end
      end
    end

    test "no guide carries the unused thumbnail field" do
      for guide <- HowToData.all_how_tos() do
        refute Map.has_key?(guide, :thumbnail), "#{guide.id} still carries a thumbnail"
      end
    end

    test "every guide's prev/next stays within its first-tag group" do
      all = HowToData.all_how_tos()

      for guide <- all do
        [tag | _] = guide.tags
        group = Enum.filter(all, &(tag in &1.tags))
        index = Enum.find_index(group, &(&1.id == guide.id))
        expected_prev = if index > 0, do: Enum.at(group, index - 1)
        expected_next = Enum.at(group, index + 1)

        {prev, next} = HowToData.get_navigation(guide)

        assert prev == expected_prev, "#{guide.id}'s previous guide is outside its #{tag} group"
        assert next == expected_next, "#{guide.id}'s next guide is outside its #{tag} group"
        assert [prev, next] |> Enum.reject(&is_nil/1) |> Enum.all?(&(tag in &1.tags))
      end
    end
  end

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

    test "keeps acronyms in capitals, only as whole words" do
      assert HowToData.format_tag("api") == "API"
      assert HowToData.format_tag("ai-agents") == "AI Agents"
      assert HowToData.format_tag("apis-and-aims") == "Apis And Aims"
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
    test "all 5 developer guides exist" do
      developer_guides =
        HowToData.all_how_tos()
        |> Enum.filter(&("developer" in &1.tags))

      assert length(developer_guides) == 5

      guide_ids = Enum.map(developer_guides, & &1.id)
      assert "setting-up-hooks" in guide_ids
      assert "api-authentication" in guide_ids
      assert "claim-complete-workflow" in guide_ids
      assert "debugging-hooks" in guide_ids
      assert "connecting-an-mcp-client" in guide_ids
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
    test "all 5 non-developer guides exist" do
      non_dev_guides =
        HowToData.all_how_tos()
        |> Enum.filter(&("non-developer" in &1.tags))

      assert length(non_dev_guides) == 5

      guide_ids = Enum.map(non_dev_guides, & &1.id)
      assert "writing-tasks-for-ai" in guide_ids
      assert "monitoring-task-progress" in guide_ids
      assert "reviewing-completed-work" in guide_ids
      assert "reading-a-tasks-details" in guide_ids
      assert "commenting-and-mentioning" in guide_ids
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

      assert File.read!("lib/kanban/tasks/agent_workflow/claiming.ex") =~
               "DateTime.add(60 * 60, :second)"

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

      assert File.read!("lib/kanban/tasks/agent_workflow/claiming.ex") =~
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
      claiming = File.read!("lib/kanban/tasks/agent_workflow/claiming.ex")

      assert workflow =~ "A claim lasts 60 minutes"
      assert claiming =~ "DateTime.add(60 * 60, :second)"
      assert workflow =~ "moves it to **Doing**"
      assert claiming =~ ~s{get_column_by_name(board_id, "Doing")}
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

    test "includes the organizations tags" do
      assert "organizations" in HowToData.all_tags()
      assert "workspaces" in HowToData.all_tags()
    end

    test "includes the org-admin tags" do
      assert "admin" in HowToData.all_tags()
    end

    test "includes the task-details tags" do
      for tag <- ~w(non-developer reviewing tasks) do
        assert tag in HowToData.all_tags()
      end

      for id <- @task_details_ids,
          {:ok, guide} = HowToData.get_how_to(id),
          tag <- guide.tags do
        assert tag in HowToData.all_tags(), "#{id} uses #{tag}, which isn't in all_tags"
      end
    end

    test "includes the notifications-and-integrations tags" do
      for tag <- ~w(notifications integrations monitoring automation api developer) do
        assert tag in HowToData.all_tags()
      end

      for id <- @notifications_integrations_ids,
          {:ok, guide} = HowToData.get_how_to(id),
          tag <- guide.tags do
        assert tag in HowToData.all_tags(), "#{id} uses #{tag}, which isn't in all_tags"
      end
    end

    test "includes the agents-and-planning tags" do
      for tag <- ~w(planning ai-agents monitoring workflow) do
        assert tag in HowToData.all_tags()
      end
    end

    test "includes the boards tags" do
      for tag <- ~w(boards tasks monitoring workflow) do
        assert tag in HowToData.all_tags()
      end
    end
  end

  describe "total guide count" do
    test "has all 42 guides" do
      assert length(HowToData.all_how_tos()) == 42
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
  end

  describe "account guides" do
    defp account_content(ids) do
      for id <- ids,
          {:ok, guide} = HowToData.get_how_to(id),
          step <- guide.steps,
          into: "",
          do: step.content <> "\n"
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

  describe "organizations guides" do
    defp organization_content(ids) do
      for id <- ids,
          {:ok, guide} = HowToData.get_how_to(id),
          step <- guide.steps,
          into: "",
          do: step.content <> "\n"
    end

    test "the organizations guides exist with their tags and steps" do
      expected = [
        {"free-and-paid-boards", "Free and Paid Boards", ["organizations", "boards"], 7},
        {"working-in-a-workspace", "Working in a Workspace", ["organizations", "workspaces"], 9},
        {"accepting-an-invitation", "Accepting an Invitation",
         ["organizations", "workspaces", "beginner"], 6}
      ]

      assert Enum.map(KanbanWeb.ResourcesLive.HowTos.Organizations.how_tos(), & &1.id) ==
               @organization_ids

      for {id, title, tags, min_steps} <- expected do
        assert {:ok, guide} = HowToData.get_how_to(id)
        assert guide.title == title
        assert guide.tags == tags
        assert guide.created_at == ~D[2026-10-24]
        assert length(guide.steps) >= min_steps, "#{id} lost steps"
      end

      # Only these and the org-admin guides lead with the tag, so navigation
      # runs through the trio and on into the org-admin guides.
      assert Enum.filter(HowToData.all_how_tos(), &(List.first(&1.tags) == "organizations"))
             |> Enum.map(& &1.id) == @organization_ids ++ @org_admin_ids
    end

    test "the organizations guides navigate free and paid → workspace → invitation" do
      [free, workspace, invitation] =
        Enum.map(@organization_ids, fn id ->
          {:ok, guide} = HowToData.get_how_to(id)
          guide
        end)

      assert {nil, %{id: "working-in-a-workspace"}} = HowToData.get_navigation(free)

      assert {%{id: "free-and-paid-boards"}, %{id: "accepting-an-invitation"}} =
               HowToData.get_navigation(workspace)

      assert {%{id: "working-in-a-workspace"}, %{id: "administering-your-organization"}} =
               HowToData.get_navigation(invitation)
    end

    test "the organizations guides link to pages that exist" do
      content = organization_content(@organization_ids)
      ids = Enum.map(HowToData.all_how_tos(), & &1.id)

      links = Regex.scan(~r/\]\((\/[^)]+)\)/, content, capture: :all_but_first) |> List.flatten()
      assert "/pricing" in links

      for "/resources/" <> id <- links do
        assert id in ids, "an organizations guide links to the missing guide #{id}"
      end

      assert File.read!("lib/kanban_web/router.ex") =~
               ~s(get "/pricing", PageController, :pricing)
    end

    test "the free and paid board facts match the code" do
      free = organization_content(["free-and-paid-boards"])
      plans = File.read!("lib/kanban/plans.ex")

      assert free =~ "A free board holds up to 3 people"
      assert plans =~ "@free_board_member_cap 3"
      assert plans =~ "member_count >= @free_board_member_cap and not board_unlocked?(board)"

      assert free =~
               "The limits in this guide apply only when your Stride instance switches its plans on"

      assert plans =~ "Application.get_env(:kanban, :plans_enforced, false) == true"

      assert free =~ "Removing people always works, but nobody new can join"

      for label <- ["Bulk actions", "Telemetry", "MCP", "Integrations", "Notifications"] do
        assert free =~ "**#{label}**"
      end

      refute free =~ "Everything else on the board works as usual"

      assert File.read!("lib/kanban_web/mcp/server.ex") =~
               "Plans.check_board(board, :mcp, surface: :mcp)"

      assert free =~
               "to reach **Get Stride for your organization** on the [Pricing](/pricing) page, where **Talk to us** emails the Stride team"

      refute free =~ "contact form"
      pricing = File.read!("lib/kanban_web/controllers/page_html/pricing.html.heex")
      assert pricing =~ ~s(id="contact")
      assert pricing =~ ~s(href="mailto:)

      assert File.read!("lib/kanban_web/controllers/locked_feature_controller.ex") =~
               ~s(redirect(conn, to: ~p"/pricing" <> "#contact"\))

      assert free =~
               "the switched-on ones are marked Paused until the board moves into an Organization"

      assert File.read!("lib/kanban_web/live/board_live/webhook_state.ex") =~
               "Sends again once this board moves into an Organization."

      assert free =~ "they come only from paid boards"

      assert File.read!("lib/kanban/notifications.ex") =~
               "drops every event on a board that\n  is not paid"

      assert free =~ "a board can't be moved back"

      assert File.read!("lib/kanban_web/live/workspace_live/settings.html.heex") =~
               "Boards can't be moved back."
    end

    test "the workspace facts match the code" do
      workspace = organization_content(["working-in-a-workspace"])
      settings = File.read!("lib/kanban_web/live/workspace_live/settings.ex")

      assert settings =~
               ~s|{:members, gettext("Members"), gettext("roles · removal")},\n      {:boards, gettext("Boards"), gettext("list · move a board here")}\n    ] ++\n      if can_manage?,|

      assert workspace =~ "Org-admins also see **Invitations**, **Tokens** and **Export**"

      assert workspace =~ "Your personal boards are not in the list"

      assert File.read!("lib/kanban/workspaces/listing.ex") =~
               "A personal workspace is\n  never returned"

      assert workspace =~
               "A Guest works on the boards they are invited to, but can't create boards there"

      assert File.read!("lib/kanban/workspaces/policy.ex") =~ "where: m.role == ^:member"

      assert workspace =~ "a link that works once and expires in 7 days"
      assert File.read!("lib/kanban/workspaces/invitation.ex") =~ "@validity_days 7"

      assert workspace =~ "It acts as you and expires in 90 days"

      assert File.read!("lib/kanban_web/live/workspace_live/tokens_card.ex") =~
               "It expires in 90 days."

      assert workspace =~ "zip archive"
      assert workspace =~ "Archives are kept for 7 days, and only org-admins can download them"
      assert File.read!("lib/kanban/workspaces/export.ex") =~ "@retention_days 7"

      assert workspace =~
               "Changing a Member to a Guest also revokes any open invitation sent to that person"

      assert File.read!("lib/kanban/workspaces/members.ex") =~
               "Lowering a\n  `:member` to `:guest` revokes the open invitations addressed to `user`"
    end

    test "the invitation facts match the code" do
      invitation = organization_content(["accepting-an-invitation"])
      messages = File.read!("lib/kanban_web/live/workspace_live/invitation_messages.ex")

      assert invitation =~ "a link that works once and expires after 7 days"
      assert invitation =~ "The invitation is accepted when you confirm your email"
      assert invitation =~ "Nothing changes until you click **Accept invitation**"

      assert invitation =~ "clicking **Accept invitation** shows **This board is full**"
      assert invitation =~ "Your invitation stays open"

      assert messages =~
               "This board is full: free boards hold %{cap} people. Ask the board owner to make room, then open the link again."

      assert messages =~ "This invitation link is invalid or has expired."

      assert invitation =~
               "for a workspace invitation, when you already belong to a different Organization"

      assert File.read!("lib/kanban/workspaces/invitation_acceptance.ex") =~
               "defp in_other_organization?(%Invitation{role: nil}, _user), do: false"

      assert File.read!("lib/kanban_web/live/user_live/confirmation.ex") =~
               "# An account registered from an invitation link joins once its email is"
    end
  end

  describe "org-admin guides" do
    defp org_admin_content(ids) do
      for id <- ids,
          {:ok, guide} = HowToData.get_how_to(id),
          step <- guide.steps,
          into: "",
          do: step.content <> "\n"
    end

    test "the org-admin guides exist with their tags and steps" do
      expected = [
        {"administering-your-organization", "Administering Your Organization",
         ["organizations", "admin"], 7},
        {"reading-the-organization-audit-log", "Reading the Organization Audit Log",
         ["organizations", "admin"], 7},
        {"organization-security-policy", "Setting Your Organization's Security Policy",
         ["organizations", "admin"], 5},
        {"setting-up-single-sign-on", "Setting Up Single Sign-On", ["organizations", "admin"], 7},
        {"provisioning-users-with-scim", "Provisioning Users With SCIM",
         ["organizations", "admin"], 5}
      ]

      assert Enum.map(KanbanWeb.ResourcesLive.HowTos.OrgAdmin.how_tos(), & &1.id) ==
               @org_admin_ids

      for {id, title, tags, min_steps} <- expected do
        assert {:ok, guide} = HowToData.get_how_to(id)
        assert guide.title == title
        assert guide.tags == tags
        assert guide.created_at == ~D[2026-10-24]
        assert length(guide.steps) >= min_steps, "#{id} lost steps"
        assert guide.description =~ ~r/^For org-admins: /, "#{id} doesn't say who it is for"
        refute "security" in guide.tags, "#{id} would join the security navigation chain"
      end
    end

    test "the org-admin guides continue the organizations navigation" do
      chain = ["working-in-a-workspace", "accepting-an-invitation"] ++ @org_admin_ids ++ [nil]

      for [prev, id, next] <- Enum.chunk_every(chain, 3, 1, :discard) do
        {:ok, guide} = HowToData.get_how_to(id)
        {p, n} = HowToData.get_navigation(guide)
        assert (p && p.id) == prev, "#{id} has the wrong previous guide"
        assert (n && n.id) == next, "#{id} has the wrong next guide"
      end
    end

    test "the org-admin guides link to guides that exist" do
      content = org_admin_content(@org_admin_ids)
      ids = Enum.map(HowToData.all_how_tos(), & &1.id)

      links = Regex.scan(~r/\]\((\/[^)]+)\)/, content, capture: :all_but_first) |> List.flatten()
      assert links != []

      for link <- links do
        assert "/resources/" <> id = link
        assert id in ids, "an org-admin guide links to the missing guide #{id}"
      end
    end

    test "the console facts match the code" do
      console = org_admin_content(["administering-your-organization"])
      router = File.read!("lib/kanban_web/router.ex")
      heex = File.read!("lib/kanban_web/live/org_live/console.html.heex")

      for view <- ~w(console audit_log security sso scim) do
        assert File.read!("lib/kanban_web/live/org_live/#{view}.ex") =~
                 "on_mount {KanbanWeb.UserAuth, :require_org_admin}"
      end

      assert console =~ "Members don't see the link"
      assert File.read!("lib/kanban_web/components/side_nav.ex") =~ "org_admin_membership"

      assert console =~
               "creating an Organization, changing its details, and appointing or removing org-admins"

      assert router =~ ~s(live "/organizations/new", OrganizationLive.Form, :new)
      assert heex =~ "Read-only. Ask a site admin to change them."

      assert console =~ "Org-admins have no **Remove** button"
      assert heex =~ ~r/:if=\{member\.role == :member\}/

      assert console =~ "Stride refuses to remove, disable or delete its last one"

      assert File.read!("lib/kanban/organizations/membership_writes.ex") =~
               "ensure_not_last_org_admin"

      assert console =~ "Archive** removes a workspace that no longer holds any boards"
      assert heex =~ "A workspace can be archived once it holds no boards."

      assert console =~
               "Archiving revokes the workspace's API tokens and open invitations, frees its name"

      # Boards only move from a personal workspace into an org one, so a
      # workspace is emptied by deleting its boards, never by moving them.
      refute console =~ "Move its boards out"

      assert console =~
               "Boards can't be moved out of a workspace, so their owners must delete them first"

      assert File.read!("lib/kanban/workspaces/board_moves.ex") =~ ":not_in_personal_workspace"
      assert File.read!("lib/kanban/boards.ex") =~ "Deletes a board. Owner-only."

      assert console =~
               "No two workspaces in the Organization can share a name, ignoring capitals"

      assert File.read!("lib/kanban/organizations/org_workspaces.ex") =~
               "no two unarchived workspaces share a name, compared\n  ignoring case"
    end

    test "the audit log facts match the code" do
      audit = org_admin_content(["reading-the-organization-audit-log"])
      live = File.read!("lib/kanban_web/live/org_live/audit_log.ex")
      export = File.read!("lib/kanban_web/controllers/org_audit_log_export_controller.ex")

      assert audit =~ "The log shows 50 events at a time"
      assert live =~ "@page_size 50"

      assert audit =~ "**Outside your Organization** replaces their name"
      assert live =~ ~s|gettext("Outside your Organization")|

      assert audit =~ "at most the 50,000 newest matching events"
      assert export =~ "50_000"
      assert audit =~ "You can export 10 times an hour"
      assert audit =~ "each export is itself recorded in the log"
      assert export =~ "org_audit_log_exported"

      assert audit =~ "There is no filter by person, on purpose"
    end

    test "the security policy facts match the code" do
      security = org_admin_content(["organization-security-policy"])
      policy = File.read!("lib/kanban/organizations/security_policy.ex")

      assert security =~ "from 1 to 30 days, 7 unless you change it"
      assert Kanban.Organizations.SecurityPolicy.grace_days_range() == 1..30
      assert %Kanban.Organizations.SecurityPolicy{}.two_factor_grace_days == 7

      assert security =~ "from 90 to 3650"
      assert Kanban.Organizations.SecurityPolicy.retention_days_range() == 90..3650

      assert security =~
               "Shortening the grace period while the requirement is on restarts everyone's clock"

      assert policy =~
               "grace_shortened?(changeset, policy) -> put_change(changeset, :two_factor_enforced_at, now)"

      assert security =~ "Members who sign in through single sign-on are not affected"

      assert File.read!("lib/kanban_web/live/org_live/security.html.heex") =~
               "Members who sign in through single sign-on are not affected."
    end

    test "the single sign-on and SCIM facts match the code" do
      sso = org_admin_content(["setting-up-single-sign-on"])
      scim = org_admin_content(["provisioning-users-with-scim"])
      verification = File.read!("lib/kanban/sso/domain_verification.ex")

      assert sso =~ "`_stride-verification.` followed by the domain"
      assert sso =~ "starts with `stride-verification=`"
      assert verification =~ "_stride-verification."
      assert verification =~ "stride-verification="

      assert sso =~ "after 3 checks in a row without it"
      assert File.read!("lib/kanban/sso/domain_recheck.ex") =~ "@misses_before_unverify 3"

      assert sso =~ "Stride has no setting that limits your Organization to single sign-on"
      assert sso =~ "Single sign-on never makes anyone an org-admin"

      assert scim =~ "Stride keeps only a fingerprint of it, so it can't be shown again"
      assert File.read!("lib/kanban/scim/scim_token.ex") =~ "token_hash"

      assert scim =~
               "Creating, renaming and archiving workspaces stays in the Organization console"

      assert File.read!("lib/kanban/scim/groups.ex") =~
               "Groups are created, renamed and\n  archived by org-admins in the org console, never through SCIM."

      assert scim =~ "can't deprovision your Organization's last enabled org-admin"
      assert File.read!("lib/kanban/scim/lifecycle.ex") =~ ":last_org_admin"
    end
  end

  describe "boards guides" do
    defp boards_content(ids) do
      for id <- ids,
          {:ok, guide} = HowToData.get_how_to(id),
          step <- guide.steps,
          into: "",
          do: step.content <> "\n"
    end

    test "the boards guides exist with their tags and steps" do
      expected = [
        {"managing-board-settings", "Managing Board Settings", ["boards", "tasks"], 6},
        {"finding-work-with-search-and-filters", "Finding Work With Search and Filters",
         ["boards", "monitoring"], 6},
        {"bulk-editing-cards", "Editing Many Cards at Once", ["boards", "tasks", "workflow"], 7},
        {"archiving-tasks", "Archiving Tasks", ["boards", "tasks"], 6}
      ]

      assert Enum.map(KanbanWeb.ResourcesLive.HowTos.Boards.how_tos(), & &1.id) == @boards_ids

      for {id, title, tags, min_steps} <- expected do
        assert {:ok, guide} = HowToData.get_how_to(id)
        assert guide.title == title
        assert guide.tags == tags
        assert guide.created_at == ~D[2026-10-24]
        assert length(guide.steps) >= min_steps, "#{id} lost steps"

        for tag <- ~w(getting-started developer non-developer best-practices security) do
          refute tag in guide.tags, "#{id} would join the #{tag} chain or its count"
        end
      end
    end

    test "the boards guides run from the first board to free and paid boards" do
      chain = ["creating-your-first-board"] ++ @boards_ids ++ ["free-and-paid-boards"]

      for [prev, id, next] <- Enum.chunk_every(chain, 3, 1, :discard) do
        {:ok, guide} = HowToData.get_how_to(id)
        {p, n} = HowToData.get_navigation(guide)
        assert (p && p.id) == prev, "#{id} has the wrong previous guide"
        assert (n && n.id) == next, "#{id} has the wrong next guide"
      end
    end

    test "the boards guides link to guides that exist" do
      content = boards_content(@boards_ids)
      ids = Enum.map(HowToData.all_how_tos(), & &1.id)

      links = Regex.scan(~r/\]\((\/[^)]+)\)/, content, capture: :all_but_first) |> List.flatten()
      assert links != []

      for link <- links do
        assert "/resources/" <> id = link
        assert id in ids, "a boards guide links to the missing guide #{id}"
      end
    end

    test "the settings facts match the code" do
      settings = boards_content(["managing-board-settings"])
      form = File.read!("lib/kanban_web/live/board_live/settings_form_component.ex")
      tabs = File.read!("lib/kanban_web/components/board_tabs.ex")
      boards = File.read!("lib/kanban/boards.ex")

      # Only acceptance criteria is on for a new board.
      on = for {field, true} <- %Kanban.Boards.Board{}.field_visibility, do: field
      assert on == ["acceptance_criteria"]
      assert settings =~ "A new board shows only **Acceptance Criteria**."

      # Name, description and field visibility are owner-only, and an
      # org-admin's derived access counts as owner.
      assert form =~ ":if={@is_owner}"
      assert boards =~ "get_user_access(board_id, user.id) == :owner"
      assert boards =~ "owner-equivalent access an org-admin derives"
      assert settings =~ "its org-admins can too"

      # Settings is for members; a public read-only board is open to any
      # signed-in user.
      assert tabs =~ "defp hidden?(:settings, flags), do: not flags.member?"
      assert boards =~ "if board.read_only, do: {:ok, %{board | user_access: nil}}"
      assert settings =~ "anyone signed in to Stride"

      # Labels: nine colours, 40 characters, unique ignoring capitals.
      assert length(Kanban.Labels.Label.colors()) == 9
      assert File.read!("lib/kanban/labels/label.ex") =~ "@max_name_length 40"
      assert File.read!("lib/kanban/labels.ex") =~ "in [:owner, :modify]"
      # Sharing takes a Save, and unticking reaches the server.
      assert form =~ ~s(<input type="hidden" name={f[:read_only].name} value="false" />)
      assert form =~ ~s(value="true")
      assert settings =~ "Tick **Make board publicly readable** and click **Save**"
      assert settings =~ "untick the box and click **Save**"

      assert settings =~ "pick one of nine colours"
      assert settings =~ "up to 40 characters"
      assert settings =~ "ignoring capitals"
    end

    test "the search and filter facts match the code" do
      filters = boards_content(["finding-work-with-search-and-filters"])
      board_filters = File.read!("lib/kanban/tasks/board_filters.ex")

      assert KanbanWeb.BoardLive.FilterParams.max_search_length() == 100
      assert filters =~ "A search can be up to 100 characters."

      assert board_filters =~ "against the title or the identifier"
      assert filters =~ "part of a task's title or its ID"
      assert filters =~ "It doesn't search descriptions."

      assert board_filters =~
               "or when\n      it is a goal with at least one non-archived child that matches"

      assert filters =~ "A goal stays on the board while one of its tasks matches"
    end

    test "the bulk action facts match the code" do
      bulk = boards_content(["bulk-editing-cards"])
      actions = File.read!("lib/kanban/tasks/bulk_actions.ex")

      assert actions =~ "Boards.get_user_access(board_id, user_id) in [:owner, :modify]"
      assert bulk =~ "The board's owner and members with modify access see **Select**"

      assert actions =~ "Goals are skipped by move, assign and archive"
      assert actions =~ "Labels apply to goals too."
      assert bulk =~ "Goals are skipped, because a goal moves with its tasks."
      assert bulk =~ "they apply to goals as well"

      # The bar shows in select mode; Esc only empties the selection.
      show = File.read!("lib/kanban_web/live/board_live/show.html.heex")
      selection = File.read!("lib/kanban_web/live/board_live/bulk_selection.ex")
      assert show =~ ":if={@can_modify and (@selection_mode or"
      assert File.read!("assets/js/hooks/keyboard_shortcuts.js") =~ ~s|pushEvent("bulk_clear"|

      assert selection =~
               ~s|selection_event("bulk_clear", _params, socket),\n    do: socket \|> assign(:selected_ids, MapSet.new())|

      assert bulk =~ "show a checkbox on every card and the bulk bar above the columns"
      assert bulk =~ "**Esc** unticks every card but leaves you selecting."

      assert actions =~ "{:error, :wip_limit_reached}"
      assert bulk =~ "past its WIP limit, nothing moves"
      assert actions =~ "so an action succeeds or fails as\n  a whole"
      assert bulk =~ "changes every selected card or none of them"
    end

    test "the archive facts match the code" do
      archive = boards_content(["archiving-tasks"])
      archiving = File.read!("lib/kanban/tasks/archiving.ex")
      index = File.read!("lib/kanban_web/live/archive_live/index.ex")
      export = File.read!("lib/kanban_web/controllers/archive_export_controller.ex")

      # Archive old: completed more than 30 days ago, in any column.
      assert archiving =~ "cutoff_days \\\\ 30"
      assert archiving =~ "where: t.status == :completed"
      refute archiving =~ ~r/bulk_archive_completed_tasks_older_than.*column_id/s
      assert archive =~ "completed more than 30 days ago, whichever column it's in"

      # Restore and Delete forever: owner and modify.
      assert index =~ "assign(:can_modify, user_access in [:owner, :modify])"
      assert index =~ ~s|gettext("Restore")|
      assert index =~ ~s|gettext("Delete forever")|
      assert archive =~ "The board's owner and members with modify access see both."

      # Restore goes to the bottom of the column and drops a lost assignee.
      assert archiving =~ "Positioning.get_next_position_locked(column)"
      assert archiving =~ "drop_assignee_without_write_access"
      assert archive =~ "at the bottom of the column it came from"
      assert archive =~ "comes back unassigned"

      # The CSV: every archived task, its columns, any viewer.
      assert export =~ "Boards.get_board(board_id, user)"
      assert export =~ "Archives.export_csv_for_board(board.id)"

      assert File.read!("lib/kanban/archives.ex") =~
               ~s|@csv_headers ~w(Identifier Title Type Goal Assignee)a ++\n                 ["Archive Reason", "Archived At", "Archived By"]|

      assert archive =~
               "its ID, title, type, goal, assignee, archive reason, when it was archived and who archived it"
    end
  end

  describe "agents and planning guides" do
    defp agents_and_planning_content(ids) do
      for id <- ids,
          {:ok, guide} = HowToData.get_how_to(id),
          step <- guide.steps,
          into: "",
          do: step.content <> "\n"
    end

    test "the agents and planning guides exist with their tags and steps" do
      expected = [
        {"watching-your-agents", "Watching Your Agents", ["ai-agents", "monitoring"], 9},
        {"your-work-across-boards", "Your Work Across Boards", ["planning", "workflow"], 5},
        {"planning-with-targets", "Planning With Targets", ["planning", "workflow"], 9}
      ]

      assert Enum.map(KanbanWeb.ResourcesLive.HowTos.AgentsAndPlanning.how_tos(), & &1.id) ==
               @agents_and_planning_ids

      for {id, title, tags, min_steps} <- expected do
        assert {:ok, guide} = HowToData.get_how_to(id)
        assert guide.title == title
        assert guide.tags == tags
        assert guide.created_at == ~D[2026-10-24]
        assert length(guide.steps) >= min_steps, "#{id} lost steps"

        for tag <-
              ~w(getting-started developer non-developer best-practices security boards organizations metrics collaboration) do
          refute tag in guide.tags, "#{id} would join the #{tag} chain or its count"
        end
      end
    end

    test "the agents guide ends the ai-agents chain and the planning pair stands alone" do
      {:ok, watching} = HowToData.get_how_to("watching-your-agents")
      {prev, next} = HowToData.get_navigation(watching)
      assert prev.id == "writing-tasks-for-ai"
      assert next == nil

      chain = [nil, "your-work-across-boards", "planning-with-targets", nil]

      for [prev, id, next] <- Enum.chunk_every(chain, 3, 1, :discard) do
        {:ok, guide} = HowToData.get_how_to(id)
        {p, n} = HowToData.get_navigation(guide)
        assert (p && p.id) == prev, "#{id} has the wrong previous guide"
        assert (n && n.id) == next, "#{id} has the wrong next guide"
      end
    end

    test "the agents and planning guides link to guides that exist" do
      content = agents_and_planning_content(@agents_and_planning_ids)
      ids = Enum.map(HowToData.all_how_tos(), & &1.id)

      links = Regex.scan(~r/\]\((\/[^)]+)\)/, content, capture: :all_but_first) |> List.flatten()
      assert links != []

      for link <- links do
        assert "/resources/" <> id = link
        assert id in ids, "an agents or planning guide links to the missing guide #{id}"
      end
    end

    test "the intervention facts match the code" do
      agents = agents_and_planning_content(["watching-your-agents"])
      interventions = File.read!("lib/kanban/tasks/interventions.ex")
      transactions = File.read!("lib/kanban/tasks/intervention_transactions.ex")
      live_interventions = File.read!("lib/kanban_web/live/agents_live/interventions.ex")
      live = File.read!("lib/kanban_web/live/agents_live.ex")

      # Who can step in: the target owner on an accessible board, or the board
      # owner (an org-admin counts as owner).
      assert interventions =~ "owner?(goal, user) and accessible?(scope, goal)"

      assert interventions =~
               "Targets.owner?(target, user) or Boards.owner?(goal.column.board, user)"

      assert File.read!("lib/kanban/boards.ex") =~ "owner-equivalent access an org-admin derives"

      assert agents =~
               "the target's owner, if they also belong to the goal's board, with any access, or"

      assert agents =~ "An org-admin counts as the owner of their Organization's boards."

      # Only not-started, unclaimed children change.
      assert transactions =~ "where: t.column_id in ^not_started_column_ids"
      assert transactions =~ "status == :open end)"
      assert agents =~ "haven't started yet and that no one has claimed"

      # Who is offered, and who is notified.
      assert interventions =~ "Read-only members are left out"

      assert interventions =~
               "One task_assigned notification for the goal, never one per moved child."

      assert interventions =~ "deliberately narrower than the `Lifecycle` assignment"

      assert File.read!("lib/kanban/notifications.ex") =~
               "drops every event on a board that\n  is not paid"

      assert interventions =~ "when new_id != old_id do"

      assert File.read!("lib/kanban/notifications/events.ex") =~
               "defp emit_task_assigned(%Task{assigned_to_id: id}, %{id: id}), do: :ok"

      assert agents =~
               "one notification, for the goal, unless the goal was already theirs or you picked yourself"

      assert agents =~ "Other members don't see them"
      refute agents =~ "Members with modify or read-only access don't see them"
      assert agents =~ "notifications only come from paid boards"

      # Undo lasts 8 seconds, only for the latest change, and lives in the page.
      assert live_interventions =~ "@default_undo_window_ms 8_000"
      assert live =~ "undo: nil"
      assert live =~ "def handle_info({:clear_undo, token}"
      assert agents =~ "offers **Undo** for 8 seconds"
      assert agents =~ "after you make another change, or after you reload or leave the page"
    end

    test "the roster and feed facts match the code" do
      agents = agents_and_planning_content(["watching-your-agents"])
      roster = File.read!("lib/kanban/agents/roster.ex")

      assert roster =~ "@stuck_threshold_minutes 60"
      assert agents =~ "hasn't moved for over an hour"
      assert roster =~ "Enum.any?(tasks, &Agents.doing?/1) -> :working"
      assert roster =~ "Enum.any?(tasks, &Agents.in_review?/1)"
      assert agents =~ "agents with a task in Review and none in Doing"

      # Stalls explain an at-risk target; only lag or a slipped estimate cause one.
      assert File.read!("lib/kanban/targets/status.ex") =~
               "lagging?(target, goal_progress, today) or slipped?(estimate, target.target_date) -> :at_risk"

      assert agents =~
               "A target turns **At-risk** when its work falls behind or its estimate slips"

      refute agents =~ "because a goal has stalled"
      assert roster =~ "@dormant_threshold_days 14"
      assert agents =~ "no activity for 14 days"

      assert File.read!("lib/kanban_web/live/agents_live/data_loader.ex") =~
               "@recent_activity_limit 200"

      assert agents =~ "the latest 200 events"
      assert File.read!("lib/kanban/agents/detail.ex") =~ "@agent_detail_activity_limit 20"
      assert agents =~ "its last 20 events"
    end

    test "the My Work facts match the code" do
      my_work = agents_and_planning_content(["your-work-across-boards"])
      context = File.read!("lib/kanban/tasks/my_work.ex")
      live = File.read!("lib/kanban_web/live/my_work_live.ex")

      assert context =~
               "t.assigned_to_id == ^user_id and is_nil(t.archived_at) and t.status != :completed"

      assert context =~ ~s|c.name) != "done"|
      assert my_work =~ "aren't completed or archived"
      assert my_work =~ "Anything in a Done column is left out."

      assert context =~ "an assignment on a public board they never joined"
      assert my_work =~ "A shared board you never joined"

      assert context =~ "asc: b.name"
      assert context =~ "WHEN 'critical' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2"
      assert my_work =~ "**Critical**, **High**, **Medium**, **Low**, then by ID"

      assert live =~ "max={3}"
      assert my_work =~ "up to three labels"

      refute live =~ "handle_info"
      assert my_work =~ "doesn't update by itself"
    end

    test "the target facts match the code" do
      planning = agents_and_planning_content(["planning-with-targets"])
      targets = File.read!("lib/kanban/targets.ex")
      show = File.read!("lib/kanban_web/live/target_live/show.ex")

      assert File.read!("lib/kanban/targets/delivery_target.ex") =~
               "validate_required([:name, :target_date])"

      assert planning =~ "**Name** and **Target Date** are required"

      assert File.read!("lib/kanban/targets/queries.ex") =~
               "t.type == :goal and is_nil(t.target_id)"

      assert planning =~ "aren't in a target yet"
      assert File.read!("lib/kanban_web/live/target_live/form.ex") =~ "hide_archived: true"
      assert planning =~ "**Hide archived goals** starts ticked"

      assert targets =~ "Boards.get_user_access(board_id, user_id) in [:owner, :modify]"
      assert planning =~ "you need owner or modify access on its board"

      assert show =~ "Targets.get_owned_target(scope, id)"
      assert planning =~ "Only the owner can open a target's page."

      assert File.read!("lib/kanban/targets/status.ex") =~ "@lag_threshold 0.15"
      assert planning =~ "by more than 15 points"

      assert File.read!("lib/kanban_web/live/target_live/show.html.heex") =~
               ":if={@summary.status == :complete and not @archived?}"

      assert planning =~ "Once a target is **Complete**, its owner sees **Archive target**"

      assert File.read!("lib/kanban_web/live/target_live/archived.ex") =~
               "listing is board-scoped but mutation is owner-scoped"

      assert planning =~
               "only a target's owner can unarchive it. Anyone else gets **Target not found**."

      # Opening a child from the goal page goes to the task editor, which needs
      # owner or modify access.
      assert File.read!("lib/kanban_web/live/goal_live/show.ex") =~
               ~s|to: ~p"/boards/\#{socket.assigns.board}/tasks/\#{id}/edit"|

      assert File.read!("lib/kanban_web/live/board_live/authorization.ex") =~
               "You do not have permission to modify tasks on this board"

      assert planning =~ "Clicking one opens it for editing, which needs owner or modify access."
    end

    test "the guides claim no plan gate and avoid the public goal-page case" do
      for path <-
            @agents_and_planning_sources ++
              ["lib/kanban/tasks/interventions.ex", "lib/kanban/tasks/my_work.ex"] do
        refute File.read!(path) =~ ~r/Plans\.|plans_enforced|LockedFeature/,
               "#{path} has a plan gate the guides don't mention"
      end

      # A non-member on a publicly readable board sees no children on the goal
      # page (tasks/queries.ex list_children_for_goal), so the guide only
      # promises the page to board members.
      planning = agents_and_planning_content(["planning-with-targets"])
      assert planning =~ "Members of the board can open it."
      refute planning =~ ~r/publicly|shared board/i
    end
  end

  describe "task details guides" do
    defp task_details_content(ids) do
      for id <- ids,
          {:ok, guide} = HowToData.get_how_to(id),
          step <- guide.steps,
          into: "",
          do: step.content <> "\n"
    end

    test "the task details guides exist with their tags and steps" do
      expected = [
        {"reading-a-tasks-details", "Reading a Task's Details",
         ["non-developer", "reviewing", "tasks"], 9},
        {"commenting-and-mentioning", "Commenting and Mentioning", ["non-developer", "tasks"], 7}
      ]

      assert Enum.map(KanbanWeb.ResourcesLive.HowTos.TaskDetails.how_tos(), & &1.id) ==
               @task_details_ids

      for {id, title, tags, min_steps} <- expected do
        assert {:ok, guide} = HowToData.get_how_to(id)
        assert guide.title == title
        assert guide.tags == tags
        assert guide.created_at == ~D[2026-10-24]
        assert length(guide.steps) >= min_steps, "#{id} lost steps"

        for tag <-
              ~w(getting-started developer best-practices security boards organizations metrics collaboration ai-agents planning) do
          refute tag in guide.tags, "#{id} would join the #{tag} chain or its count"
        end
      end
    end

    test "the task details guides extend the non-developer chain after reviewing" do
      {:ok, reviewing} = HowToData.get_how_to("reviewing-completed-work")
      {prev, next} = HowToData.get_navigation(reviewing)
      assert prev.id == "monitoring-task-progress"
      assert next.id == "reading-a-tasks-details"

      chain = [
        "reviewing-completed-work",
        "reading-a-tasks-details",
        "commenting-and-mentioning",
        nil
      ]

      for [prev, id, next] <- Enum.chunk_every(chain, 3, 1, :discard) do
        {:ok, guide} = HowToData.get_how_to(id)
        {p, n} = HowToData.get_navigation(guide)
        assert (p && p.id) == prev, "#{id} has the wrong previous guide"
        assert (n && n.id) == next, "#{id} has the wrong next guide"
      end
    end

    test "the task details guides link to guides that exist" do
      content = task_details_content(@task_details_ids)
      ids = Enum.map(HowToData.all_how_tos(), & &1.id)

      links = Regex.scan(~r/\]\((\/[^)]+)\)/, content, capture: :all_but_first) |> List.flatten()
      assert links != []

      for link <- links do
        assert "/resources/" <> id = link
        assert id in ids, "a task details guide links to the missing guide #{id}"
      end
    end

    test "the task view facts match the code" do
      details = task_details_content(["reading-a-tasks-details"])
      view = File.read!("lib/kanban_web/live/task_live/view_component.ex")
      panels = File.read!("lib/kanban_web/review_report_helpers/panels.ex")

      # Field visibility: only acceptance criteria is on by default.
      defaults = %Kanban.Boards.Board{}.field_visibility
      assert defaults["acceptance_criteria"] == true

      for key <- ~w(context key_files behaviour_test_matrix observability) do
        assert defaults[key] == false, "#{key} is on by default"
      end

      assert details =~ "Only **Acceptance Criteria** is on by default."

      # Observability: Telemetry and Metrics are paid; Logging stays.
      assert view =~ "do: not Plans.board_unlocked?(board_id)"
      assert view =~ "defp observability_shown?(task, true), do: !!task.logging_requirements"

      assert File.read!("lib/kanban/plans.ex") =~
               "def board_unlocked?(board), do: not enforced?() or paid_board?(board)"

      assert details =~
               "a free board doesn't show them. The values stay on the task, and **Logging** still shows."

      # When the agent's sections appear.
      assert panels =~ "review_or_done?(task) and has_completion_content?(task)"
      assert panels =~ "review_or_done?(task) and has_changed_files?(task)"

      assert File.read!("lib/kanban_web/review_report_helpers/explorer.ex") =~
               "has_explorer_result?(task) and Panels.review_or_done?(task)"

      assert details =~ "Once a task reaches Review, it shows what the agent reported"

      assert view =~
               "@task.status == :completed && (@task.actual_complexity || @task.actual_files_changed || @task.time_spent_minutes)"

      assert details =~ "**Actual vs estimated** appears once the task is Done."

      # The checklist here is never ticked; verdicts live in the Review queue.
      assert view =~ ~s|"0/\#{total}"|
      assert details =~ "The list isn't ticked off here"

      # Who sees what.
      assert File.read!("lib/kanban_web/live/task_live/components/task_detail_aside.ex") =~
               ":if={@can_modify && @board_id}"

      assert File.read!("lib/kanban_web/live/task_live/components/completion_section.ex") =~
               "deliberately not gated on board membership (D209)"

      assert details =~ "including someone signed in who is viewing a shared board"
      assert view =~ ~s|field_visible?(@field_visibility, "behaviour_test_matrix")|

      for field <- ~w(patterns_to_follow database_changes validation_rules) do
        assert view =~ "@task.#{field} && field_visible?(@field_visibility, \"technical_notes\")"
      end

      assert details =~ "which share the **Technical Notes** toggle"

      assert File.read!("lib/kanban_web/components/review_diff_panel.ex") =~
               ~s|gettext("Diff truncated at 500 lines.")|

      refute details =~ "Re-fetch diff"
    end

    test "the comment facts match the code" do
      comments = task_details_content(["commenting-and-mentioning"])
      policy = File.read!("lib/kanban/tasks/comment_policy.ex")
      notifier = File.read!("lib/kanban/tasks/comment_notifier.ex")
      notifications = File.read!("lib/kanban/notifications.ex")

      # Who can comment, edit and delete.
      assert policy =~ "def allowed?(%{access: access}, :comment), do: not is_nil(access)"
      assert policy =~ "members are included; non-members are refused"

      assert comments =~
               "Every member of the board can comment, including members with read-only access"

      assert File.read!("lib/kanban_web/live/task_live/comment_thread_component.ex") =~
               ":if={@can_comment}"

      assert policy =~ "def allowed?(viewer, :edit, %TaskComment{author_user_id: author_id}),"
      assert policy =~ "def allowed?(%{access: :owner}, :delete, %TaskComment{}), do: true"
      assert policy =~ "Kanban.Boards.get_user_access/2"
      assert File.read!("lib/kanban/boards.ex") =~ "owner-equivalent access an org-admin derives"
      assert comments =~ "Only the person who wrote a comment can edit it"
      assert comments =~ "the board's owner can delete anyone's; an org-admin counts as the owner"

      # Limits and order.
      assert Kanban.Tasks.TaskComment.content_max_length() == 10_000
      assert comments =~ "up to 10,000 characters"
      assert Kanban.Tasks.Mentions.max_mentions() == 20
      assert comments =~ "up to 20 people in one comment"

      assert File.read!("lib/kanban_web/live/task_live/comment_thread_component.ex") =~
               "@mention_limit 8"

      assert comments =~ "A list of up to 8 board members appears"
      assert File.read!("lib/kanban/tasks/comments.ex") =~ "asc: c.inserted_at, asc: c.id"
      assert comments =~ "Comments are listed oldest first."
      assert File.read!("lib/kanban/tasks/comments.ex") =~ "active_only: true"

      # Who is notified.
      assert notifier =~ "id == comment.author_user_id or MapSet.member?(previous, id)"
      assert notifier =~ "leaves the mentions unchanged notifies nobody"
      assert comments =~ "Editing a comment notifies only the people the edit adds"
      assert Kanban.Notifications.default_preference(:mentioned).email == true
      assert Kanban.Notifications.default_preference(:mentioned).in_app == true
      assert comments =~ "Mentions arrive in Stride and by email."

      # A plain comment notifies nobody: nothing emits :comment_added.
      for path <- Path.wildcard("lib/kanban/**/*.ex"),
          path not in ["lib/kanban/notifications.ex", "lib/kanban/notifications/preference.ex"] do
        refute File.read!(path) =~ "comment_added", "#{path} now emits comment notifications"
      end

      assert comments =~ "A comment with no mention notifies nobody"

      # The notification links to the edit form, which needs modify access.
      assert notifier =~
               ~s|url_path: "/boards/\#{board_id}/tasks/\#{task.id}/edit#comment-\#{comment.id}"|

      assert File.read!("lib/kanban_web/live/board_live/authorization.ex") =~
               "if user_access in [:owner, :modify] do"

      assert comments =~ "A read-only member lands on the board instead"

      # Paid rule.
      assert notifications =~ "if Plans.board_unlocked?(board_id), do: :ok, else: {:ok, []}"

      assert File.read!("lib/kanban/notifications/email_worker.ex") =~
               "plan_verdict(Plans.user_unlocked?(user) and Plans.board_unlocked?(board_id))"

      assert notifications =~ "Plans.check_user(scope, :notifications"

      assert comments =~
               "When Stride's plans are switched on, a free board sends no notifications."

      for path <- ["lib/kanban/tasks/comment_policy.ex", "lib/kanban/tasks/comments.ex"] do
        refute File.read!(path) =~ ~r/Plans\./, "#{path} now gates comments on a plan"
      end

      assert comments =~ "Comments and mentions themselves work on every board."
    end
  end

  describe "notifications and integrations guides" do
    defp notifications_integrations_content(ids) do
      for id <- ids,
          {:ok, guide} = HowToData.get_how_to(id),
          step <- guide.steps,
          into: "",
          do: step.content <> "\n"
    end

    test "the notifications-and-integrations guides exist with their tags and steps" do
      expected = [
        {"staying-informed-with-notifications", "Staying Informed With Notifications",
         ["notifications", "integrations", "monitoring"], 7},
        {"connecting-webhooks-slack-and-discord", "Connecting Webhooks, Slack and Discord",
         ["integrations", "notifications", "automation"], 6},
        {"connecting-an-mcp-client", "Connecting an MCP Client",
         ["developer", "api", "automation"], 5}
      ]

      assert Enum.map(
               KanbanWeb.ResourcesLive.HowTos.NotificationsAndIntegrations.how_tos(),
               & &1.id
             ) == @notifications_integrations_ids

      for {id, title, tags, min_steps} <- expected do
        assert {:ok, guide} = HowToData.get_how_to(id)
        assert guide.title == title
        assert guide.tags == tags
        assert guide.created_at == ~D[2026-10-24]
        assert length(guide.steps) >= min_steps, "#{id} lost steps"

        for tag <-
              ~w(getting-started non-developer best-practices security boards organizations metrics collaboration ai-agents planning) do
          refute tag in guide.tags, "#{id} would join the #{tag} chain or its count"
        end
      end

      for id <- ["staying-informed-with-notifications", "connecting-webhooks-slack-and-discord"] do
        {:ok, guide} = HowToData.get_how_to(id)
        refute "developer" in guide.tags, "#{id} would join the developer chain"
      end
    end

    test "the notifications-and-integrations guides navigate as a pair and the MCP guide ends the developer chain" do
      {:ok, notifications} = HowToData.get_how_to("staying-informed-with-notifications")
      {:ok, webhooks} = HowToData.get_how_to("connecting-webhooks-slack-and-discord")

      assert {nil, %{id: "connecting-webhooks-slack-and-discord"}} =
               HowToData.get_navigation(notifications)

      assert {%{id: "staying-informed-with-notifications"}, nil} =
               HowToData.get_navigation(webhooks)

      {:ok, mcp} = HowToData.get_how_to("connecting-an-mcp-client")
      assert {%{id: "debugging-hooks"}, nil} = HowToData.get_navigation(mcp)

      {:ok, debugging} = HowToData.get_how_to("debugging-hooks")

      assert {%{id: "claim-complete-workflow"}, %{id: "connecting-an-mcp-client"}} =
               HowToData.get_navigation(debugging)
    end

    test "the notifications-and-integrations guides link to guides and docs that exist" do
      content = notifications_integrations_content(@notifications_integrations_ids)
      ids = Enum.map(HowToData.all_how_tos(), & &1.id)

      links = Regex.scan(~r/\]\(([^)]+)\)/, content, capture: :all_but_first) |> List.flatten()
      assert links != []

      for link <- links do
        case link do
          "/resources/" <> id ->
            assert id in ids,
                   "a notifications or integrations guide links to the missing guide #{id}"

          "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/" <> path ->
            assert File.exists?(path), "#{link} names a file the repo doesn't have"

          other ->
            flunk("#{other} is neither a Resources guide nor a doc in the repo")
        end
      end
    end

    test "the notifications facts match the code" do
      content = notifications_integrations_content(["staying-informed-with-notifications"])
      notifications = File.read!("lib/kanban/notifications.ex")

      assert File.read!("lib/kanban_web/components/notification_bell.ex") =~
               ~s|count > 99, do: "99+"|

      assert content =~ "above that it shows 99+"
      refute content =~ "9+ " or content =~ " 9+"

      assert File.read!("lib/kanban_web/live/notification_live/index.ex") =~ "@page_size 25"
      assert content =~ "25 at a time"

      assert File.read!("config/config.exs") =~
               ~s|{"0 13 * * 1", Kanban.Notifications.DigestFanoutWorker}|

      assert content =~ "Mondays at 13:00 UTC"

      assert File.read!("lib/kanban/notifications/digest_worker.ex") =~
               "event_type: :weekly_digest, in_app: false"

      assert content =~ "never in the bell"

      assert notifications =~ "@email_off_by_default [:goal_completed, :comment_added]"
      assert content =~ "except the email for **Completed goals** and **Comments**"

      # Two gates: the board must be paid, and the user must be in an Organization.
      assert notifications =~ "A free board's events are dropped while plans are enforced"
      assert notifications =~ "Plans.check_user(scope, :notifications, surface: :context)"
      assert content =~ "a free board sends no notifications at all, even to Organization members"
      assert content =~ "only Organization members can change their preferences"

      # Comments has a preference row but nothing produces it.
      refute File.read!("lib/kanban/notifications/events.ex") =~ "comment_added"
      assert content =~ "a comment with no mention notifies nobody"

      # Unsubscribing: a confirm page, 90 days, never a paid action.
      assert File.read!("lib/kanban_web/unsubscribe_token.ex") =~ "@max_age 90 * 24 * 60 * 60"
      assert notifications =~ "turning email off is never a paid action"
      assert content =~ "opens a page that asks you to confirm"
      assert content =~ "The link works for 90 days, and unsubscribing never needs a paid plan."
    end

    test "the integrations facts match the code" do
      content = notifications_integrations_content(["connecting-webhooks-slack-and-discord"])
      webhooks = File.read!("lib/kanban/webhooks.ex")

      # Owner only; effective access makes an org-admin the owner.
      assert File.read!("lib/kanban_web/components/board_tabs.ex") =~
               "defp hidden?(:integrations, flags), do: not flags.owner?"

      assert File.read!("lib/kanban_web/live/board_live/integrations.ex") =~
               ~s|gettext("Only the board owner can manage integrations")|

      assert File.read!("lib/kanban/boards.ex") =~
               "Policy.effective_board_access(board_id, user_id)"

      assert content =~ "Only the board's owner sees the **Integrations** tab"

      assert webhooks =~ ":ok <- check_plan(board_id)"

      assert File.read!("lib/kanban_web/live/board_live/webhook_state.ex") =~
               "do: locked? and enabled and not not_sending?(endpoint)"

      assert content =~
               "Endpoints that are switched on show **Paused** and start sending again once the board moves into an Organization; a disabled endpoint stays off until you enable it."

      assert File.read!("lib/kanban/webhooks/signer.ex") =~ "@tolerance_seconds 300"
      assert content =~ "Reject a timestamp more than 5 minutes old."

      worker = File.read!("lib/kanban/webhooks/delivery_worker.ex")
      assert worker =~ "max_attempts: 8"
      assert worker =~ "@retryable_4xx [408, 429]"
      assert content =~ "up to 8 attempts over about an hour"
      assert content =~ "A 4xx response isn't retried, except 408 and 429."

      assert File.read!("lib/kanban_web/live/board_live/integrations_component.ex") =~
               "@log_size 20"

      assert content =~ "the 20 most recent attempts"

      assert webhooks =~ ~s|DeliveryWorker.enqueue(endpoint.id, "ping", payload)|
      assert webhooks =~ ":ok <- check_enabled(endpoint)"
      assert content =~ "**Send test** sends a `ping` event to an enabled endpoint."

      # There is no endpoint cap and no delivery retention to promise.
      refute webhooks =~ ~r/max_endpoints|endpoint_limit/
      refute content =~ ~r/up to \d+ endpoints|kept for \d+ days/
    end

    test "the MCP facts match the code" do
      content = notifications_integrations_content(["connecting-an-mcp-client"])
      docs = File.read!("docs/MCP.md")

      assert File.read!("lib/kanban_web/router.ex") =~ ~s|post "/mcp", McpController, :handle|

      assert File.read!("lib/kanban_web/mcp/server.ex") =~
               "Plans.check_board(board, :mcp, surface: :mcp)"

      assert File.read!("lib/kanban_web/mcp/json_rpc.ex") =~ "@plan_required -32_001"
      assert content =~ "every call returns error `-32001`"

      # The client config is the one docs/MCP.md documents.
      command =
        "claude mcp add --transport http stride https://www.stridelikeaboss.com/api/mcp \\\n  --header \"Authorization: Bearer ${STRIDE_API_TOKEN}\""

      assert docs =~ command
      assert content =~ command
      assert docs =~ ~s|"type": "http",\n      "url": "https://www.stridelikeaboss.com/api/mcp",|

      assert content =~
               ~s|"type": "http",\n      "url": "https://www.stridelikeaboss.com/api/mcp",|

      tools = File.read!("lib/kanban_web/mcp/tool_schemas.ex")

      names =
        Regex.scan(~r/"name" => "(stride_[a-z_]+)"/, tools, capture: :all_but_first)
        |> List.flatten()

      assert length(names) == 6

      for name <- names do
        assert content =~ "`#{name}`", "the MCP guide doesn't name the #{name} tool"
      end

      assert File.read!("lib/kanban_web/plugs/authenticate_api_token/board_selector.ex") =~
               ~s|@header "x-stride-board"|

      assert content =~ "needs the board's ID in an `X-Stride-Board` header on each tool call"

      # A placeholder, never a real-looking token.
      refute content =~ ~r/stride_(dev|live)?_?[A-Za-z0-9]{20,}/
      assert content =~ ~s|export STRIDE_API_TOKEN="paste-your-token-here"|
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
