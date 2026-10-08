defmodule KanbanWeb.ResourcesLive.HowTos.WorkingWithTasks do
  @moduledoc """
  Guides for writing, monitoring, reviewing and organizing tasks.

  One of the data modules `KanbanWeb.ResourcesLive.HowToData` concatenates,
  in order, into the Resources catalog.
  """

  @doc "The guides in this group, in display order."
  def how_tos do
    [
      %{
        id: "writing-tasks-for-ai",
        title: "Writing Effective Tasks for AI Agents",
        description:
          "Learn how to write clear, actionable tasks that AI agents can understand and complete successfully.",
        tags: ["non-developer", "tasks", "ai-agents"],
        content_type: "guide",
        reading_time: 5,
        thumbnail: "/images/resources/writing-tasks.png",
        created_at: ~D[2026-01-17],
        steps: [
          %{
            title: "Start with a Clear Title",
            content:
              "Your task title should describe **what** needs to be done in action-oriented language. Start with a verb like \"Add\", \"Create\", \"Fix\", or \"Update\".\n\n**Good examples:**\n\n- \"Add user authentication to the login page\"\n- \"Fix the broken image upload feature\"\n- \"Create a dashboard for viewing statistics\"\n\n**Avoid vague titles like:**\n\n- \"Work on login\" (too vague)\n- \"Bug\" (doesn't describe the problem)",
            image: nil
          },
          %{
            title: "Write a Detailed Description",
            content:
              "The description should explain **why** this task matters and **what** the expected outcome is. Include:\n\n- The problem you're solving\n- Who benefits from this change\n- Any relevant context or background\n- Links to related resources or discussions\n\nThe more context you provide, the better the AI agent can understand your intent.",
            image: nil
          },
          %{
            title: "Define Clear Acceptance Criteria",
            content:
              "Acceptance criteria tell the AI agent exactly what \"done\" looks like. Use simple, testable statements:\n\n- \"Users can log in with email and password\"\n- \"Error messages display when login fails\"\n- \"Session persists after browser refresh\"\n\nThink of acceptance criteria as a checklist that can be verified.",
            image: nil
          },
          %{
            title: "Choose the Right Priority and Complexity",
            content:
              "Help the AI agent understand how to prioritize work:\n\n**Priority levels:**\n\n- **Critical**: Blocking issues, security problems\n- **High**: Important features, significant bugs\n- **Medium**: Normal feature work\n- **Low**: Nice-to-haves, minor improvements\n\n**Complexity:**\n\n- **Small**: Simple changes, under 2 hours\n- **Medium**: Moderate effort, 2-8 hours\n- **Large**: Significant work, 8+ hours",
            image: nil
          }
        ]
      },
      %{
        id: "monitoring-task-progress",
        title: "Monitoring Task Progress",
        description:
          "Track what AI agents are working on and understand task status throughout the workflow.",
        tags: ["non-developer", "workflow", "monitoring"],
        content_type: "guide",
        reading_time: 4,
        thumbnail: "/images/resources/monitoring-progress.png",
        created_at: ~D[2026-01-17],
        steps: [
          %{
            title: "Understanding Task Columns",
            content:
              "Tasks move through columns as they progress:\n\n- **Ready**: Available tasks waiting to be claimed\n- **Doing**: Tasks currently being worked on by an agent\n- **Review**: Completed work waiting for your approval\n- **Done**: Approved and finished tasks\n\nWatch tasks move across columns to track progress.",
            image: nil
          },
          %{
            title: "Checking Who's Working on What",
            content:
              "When a task is in the **Doing** column, you can see which agent claimed it and when. This helps you understand:\n\n- Which tasks are actively being worked on\n- How long tasks have been in progress\n- Whether any tasks seem stuck\n\nIf a task stays in Doing too long, the claim may expire and the task returns to Ready.",
            image: nil
          },
          %{
            title: "Viewing Task Details",
            content:
              "Click on any task card to see its full details:\n\n- Complete description and acceptance criteria\n- Current status and assigned agent\n- Time spent and completion notes\n- Any blocking dependencies\n\nThis gives you full visibility into task progress.",
            image: nil
          },
          %{
            title: "Using Filters to Focus",
            content:
              "Filter your board view to focus on what matters:\n\n- Filter by status to see only tasks in progress\n- Filter by priority to focus on critical items\n- Filter by assignee to see specific agent work\n\nFilters help you manage large boards effectively.",
            image: nil
          }
        ]
      },
      %{
        id: "reviewing-completed-work",
        title: "Reviewing Completed Work",
        description:
          "Learn how to effectively review work completed by AI agents and provide helpful feedback.",
        tags: ["non-developer", "workflow", "reviewing"],
        content_type: "guide",
        reading_time: 5,
        thumbnail: "/images/resources/reviewing-work.png",
        created_at: ~D[2026-01-17],
        steps: [
          %{
            title: "When to Review",
            content:
              "Tasks that have **Needs Review** enabled will move to the Review column after completion. You'll be notified when work is ready for your review.\n\nReview is your chance to:\n\n- Verify the work meets requirements\n- Catch any issues before they're finalized\n- Provide feedback for improvement",
            image: nil
          },
          %{
            title: "What to Check",
            content:
              "When reviewing completed work, verify:\n\n- **Acceptance criteria**: Are all requirements met?\n- **Quality**: Does the work meet your standards?\n- **Completion notes**: Did the agent explain what was done?\n- **Test results**: Did verification steps pass?\n\nTake time to thoroughly check the work.",
            image: nil
          },
          %{
            title: "Approving Work",
            content:
              "If the work meets your requirements, approve it:\n\n1. Click the **Approve** button on the task\n2. Optionally add review notes\n3. The task moves to Done\n\nApproved work triggers the after_review hook, which may deploy changes or notify stakeholders.",
            image: nil
          },
          %{
            title: "Requesting Changes",
            content:
              "If work needs improvement:\n\n1. Click **Request Changes**\n2. Provide clear, specific feedback\n3. Explain what needs to be different\n4. The task returns to the agent for revision\n\nGood feedback helps the agent improve. Be specific about what needs to change and why.",
            image: nil
          }
        ]
      },
      %{
        id: "organizing-with-dependencies",
        title: "Organizing Tasks with Dependencies",
        description:
          "Use dependencies to ensure tasks are completed in the right order and manage complex projects effectively.",
        tags: ["best-practices", "tasks", "dependencies"],
        content_type: "guide",
        reading_time: 4,
        thumbnail: "/images/resources/dependencies.png",
        created_at: ~D[2026-01-17],
        steps: [
          %{
            title: "Understanding Dependencies",
            content:
              "Dependencies define the order tasks must be completed. If Task B depends on Task A, then Task A must be finished before Task B can start.\n\nThis prevents agents from:\n\n- Working on tasks before prerequisites are done\n- Creating merge conflicts from parallel changes\n- Building on incomplete foundations",
            image: nil
          },
          %{
            title: "When to Use Dependencies",
            content:
              "Add dependencies when:\n\n- One task builds on another's work\n- Tasks modify the same files\n- There's a logical sequence (design → implement → test)\n- Database migrations must happen before code changes\n\nDon't over-use dependencies—only add them when truly needed.",
            image: nil
          },
          %{
            title: "Creating Dependencies",
            content:
              "When creating or editing a task:\n\n1. Find the **Dependencies** field\n2. Select tasks that must complete first\n3. The dependent task will be blocked until prerequisites finish\n\nBlocked tasks show which dependencies are incomplete.",
            image: nil
          },
          %{
            title: "Dependency Best Practices",
            content:
              "Best practices:\n\n- **Keep chains short**: Long dependency chains slow down work\n- **Avoid cycles**: A can't depend on B if B depends on A\n- **Group related work**: Use Goals to organize related tasks\n- **Review regularly**: Remove dependencies when no longer needed",
            image: nil
          }
        ]
      },
      %{
        id: "using-complexity-priority",
        title: "Using Complexity and Priority Effectively",
        description:
          "Learn how to use complexity and priority settings to manage work and set expectations.",
        tags: ["best-practices", "tasks", "priority"],
        content_type: "guide",
        reading_time: 3,
        thumbnail: "/images/resources/complexity-priority.png",
        created_at: ~D[2026-01-17],
        steps: [
          %{
            title: "Understanding Complexity",
            content:
              "Complexity estimates how much effort a task requires:\n\n- **Small**: Quick fixes, simple changes (under 2 hours)\n- **Medium**: Standard feature work (2-8 hours)\n- **Large**: Significant effort, multiple components (8+ hours)\n\nComplexity helps agents pick appropriate tasks and helps you plan timelines.",
            image: nil
          },
          %{
            title: "Setting Priority Right",
            content:
              "Priority determines which tasks get attention first:\n\n- **Critical**: Drop everything—security issues, production bugs\n- **High**: Important work that should happen soon\n- **Medium**: Normal priority, standard workflow\n- **Low**: Nice-to-have, do when time allows\n\nAgents work on higher priority tasks first.",
            image: nil
          },
          %{
            title: "Balancing Complexity and Priority",
            content:
              "Consider both factors together:\n\n- **High priority + Small complexity**: Quick wins, do immediately\n- **High priority + Large complexity**: Important but needs planning\n- **Low priority + Small complexity**: Fill time between bigger tasks\n- **Low priority + Large complexity**: May never get done—reconsider if needed",
            image: nil
          },
          %{
            title: "Adjusting Over Time",
            content:
              "Revisit complexity and priority as work progresses:\n\n- Raise priority if something becomes urgent\n- Adjust complexity if estimates were wrong\n- Lower priority for tasks that are no longer relevant\n\nKeep your board reflecting current reality.",
            image: nil
          }
        ]
      }
    ]
  end
end
