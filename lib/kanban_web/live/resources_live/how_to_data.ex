defmodule KanbanWeb.ResourcesLive.HowToData do
  @moduledoc """
  Embedded how-to guide data for the Resources section.
  All content is version-controlled and deployed with the app.
  """

  @type_icons %{
    "guide" => "hero-book-open",
    "tutorial" => "hero-academic-cap",
    "reference" => "hero-document-text",
    "video" => "hero-play-circle"
  }

  @how_tos [
    %{
      id: "creating-your-first-board",
      title: "Creating Your First Board",
      description:
        "Learn how to create and configure a new Stride board for your team or project.",
      tags: ["getting-started", "beginner", "boards"],
      content_type: "guide",
      reading_time: 3,
      thumbnail: "/images/resources/board-creation.png",
      created_at: ~D[2026-01-15],
      steps: [
        %{
          title: "Navigate to the Boards Page",
          content:
            "After logging in, click on **My Boards** in the navigation bar to access your boards dashboard.",
          image: nil
        },
        %{
          title: "Click New Board",
          content:
            "Click the **New Board** button in the top right corner. You'll see two options: **New Empty Board** for a blank slate, or **New AI Optimized Board** which comes pre-configured with columns optimized for AI agent workflows.",
          image: nil
        },
        %{
          title: "Enter Board Details",
          content:
            "Give your board a descriptive name and optional description. The name should reflect the project or team that will use this board.",
          image: nil
        },
        %{
          title: "Configure Your Board",
          content:
            "Your new board is ready! You can now add columns to organize your workflow and invite team members to collaborate.",
          image: nil
        }
      ]
    },
    %{
      id: "understanding-columns",
      title: "Understanding Board Columns and Workflow",
      description:
        "Discover how columns help organize your tasks and create efficient workflows.",
      tags: ["getting-started", "beginner", "workflow"],
      content_type: "guide",
      reading_time: 4,
      thumbnail: "/images/resources/columns-workflow.png",
      created_at: ~D[2026-01-15],
      steps: [
        %{
          title: "What Are Columns?",
          content:
            "Columns represent stages in your workflow. Tasks move from left to right as they progress. Common patterns include **Ready → Doing → Review → Done** or **Backlog → In Progress → Testing → Complete**.",
          image: nil
        },
        %{
          title: "Default AI-Optimized Columns",
          content:
            "AI-optimized boards come with four columns designed for agent workflows:\n\n- **Ready**: Tasks available for claiming\n- **Doing**: Tasks currently being worked on\n- **Review**: Tasks awaiting human review\n- **Done**: Completed tasks",
          image: nil
        },
        %{
          title: "Adding Custom Columns",
          content:
            "Click **Add Column** to create a new column. Enter a name and choose its position in the workflow. You can drag columns to reorder them.",
          image: nil
        },
        %{
          title: "Column Settings",
          content:
            "Each column can be configured with WIP (Work In Progress) limits to prevent bottlenecks and keep work flowing smoothly.",
          image: nil
        }
      ]
    },
    %{
      id: "adding-your-first-task",
      title: "Adding Your First Task",
      description: "A step-by-step guide to creating tasks with all the essential fields.",
      tags: ["getting-started", "beginner", "tasks"],
      content_type: "guide",
      reading_time: 3,
      thumbnail: "/images/resources/task-creation.png",
      created_at: ~D[2026-01-15],
      steps: [
        %{
          title: "Open the Task Form",
          content:
            "Click the **+ Add Task** button at the bottom of any column, or use the keyboard shortcut **N** when focused on a column.",
          image: nil
        },
        %{
          title: "Enter Task Details",
          content:
            "Fill in the essential fields:\n\n- **Title**: A clear, action-oriented description\n- **Type**: Work, Defect, or Goal\n- **Priority**: Low, Medium, High, or Critical\n- **Description**: Detailed context and requirements",
          image: nil
        },
        %{
          title: "Add Acceptance Criteria",
          content:
            "Define what \"done\" looks like. Good acceptance criteria are specific, measurable, and testable. This helps both humans and AI agents understand exactly what's expected.",
          image: nil
        },
        %{
          title: "Save and Start Working",
          content:
            "Click **Create Task** to add it to the column. The task is now ready to be claimed and worked on.",
          image: nil
        }
      ]
    },
    %{
      id: "inviting-team-members",
      title: "Inviting Team Members",
      description: "Learn how to invite collaborators and manage board access permissions.",
      tags: ["getting-started", "beginner", "collaboration"],
      content_type: "guide",
      reading_time: 2,
      thumbnail: "/images/resources/invite-members.png",
      created_at: ~D[2026-01-15],
      steps: [
        %{
          title: "Access Board Settings",
          content:
            "From your board view, click the **Settings** icon (gear) in the top right corner to access board management options.",
          image: nil
        },
        %{
          title: "Invite by Email",
          content:
            "Enter the email address of the person you want to invite. They'll receive an email with a link to join your board.",
          image: nil
        },
        %{
          title: "Set Access Level",
          content:
            "Choose the appropriate permission level:\n\n- **Read Only**: Can view but not modify\n- **Can Edit**: Can create and edit tasks\n- **Owner**: Full control including settings",
          image: nil
        }
      ]
    },
    %{
      id: "setting-up-hooks",
      title: "Setting Up Hook Execution",
      description:
        "Configure client-side hooks for automated workflows when claiming and completing tasks.",
      tags: ["developer", "hooks", "automation"],
      content_type: "tutorial",
      reading_time: 8,
      thumbnail: "/images/resources/hooks-setup.png",
      created_at: ~D[2026-01-16],
      steps: [
        %{
          title: "Understanding Hooks",
          content:
            "Hooks are shell commands that execute on the agent's machine at specific points in the task lifecycle:\n\n- **before_doing**: Runs before claiming (e.g., `git pull`)\n- **after_doing**: Runs after completing work (e.g., `mix test`)\n- **before_review**: Runs when entering review (e.g., `gh pr create`)\n- **after_review**: Runs after approval (e.g., `git push`)",
          image: nil
        },
        %{
          title: "Create .stride.md",
          content:
            "Create a `.stride.md` file in your project root with hook definitions:\n\n```markdown\n## before_doing\n```bash\ngit pull origin main\nmix deps.get\n```\n\n## after_doing\n```bash\nmix test\nmix credo --strict\n```\n```",
          image: nil
        },
        %{
          title: "Hook Environment Variables",
          content:
            "Hooks receive environment variables with task context:\n\n- `TASK_ID`, `TASK_IDENTIFIER`, `TASK_TITLE`\n- `TASK_STATUS`, `TASK_COMPLEXITY`, `TASK_PRIORITY`\n- `BOARD_NAME`, `COLUMN_NAME`, `AGENT_NAME`",
          image: nil
        },
        %{
          title: "Blocking vs Non-Blocking",
          content:
            "**Blocking hooks** (before_doing, after_doing) must succeed for the action to proceed. If they fail, fix the issue before retrying.\n\n**Non-blocking hooks** (before_review, after_review) log errors but allow the workflow to continue.",
          image: nil
        }
      ]
    },
    %{
      id: "api-authentication",
      title: "Configuring API Authentication",
      description:
        "Set up API tokens for secure access to the Stride API from your applications.",
      tags: ["developer", "api", "security"],
      content_type: "tutorial",
      reading_time: 5,
      thumbnail: "/images/resources/api-auth.png",
      created_at: ~D[2026-01-16],
      steps: [
        %{
          title: "Generate an API Token",
          content:
            "Navigate to your board settings and click **API Tokens**. Click **Generate New Token** and give it a descriptive name like \"CI/CD Pipeline\" or \"Development\".",
          image: nil
        },
        %{
          title: "Create .stride_auth.md",
          content:
            "Create a `.stride_auth.md` file (add to `.gitignore`!):\n\n```markdown\n- **API URL:** `https://www.stridelikeaboss.com`\n- **API Token:** `stride_dev_your_token_here`\n- **User Email:** `your-email@example.com`\n```",
          image: nil
        },
        %{
          title: "Using the Token",
          content:
            "Include the token in API requests:\n\n```bash\ncurl -H \"Authorization: Bearer $STRIDE_API_TOKEN\" \\\n  $STRIDE_API_URL/api/tasks/next\n```",
          image: nil
        },
        %{
          title: "Security Best Practices",
          content:
            "- Never commit tokens to version control\n- Use environment variables in CI/CD\n- Rotate tokens periodically\n- Use separate tokens for different environments",
          image: nil
        }
      ]
    },
    %{
      id: "claim-complete-workflow",
      title: "Understanding Claim/Complete Workflow",
      description:
        "Master the task lifecycle with claiming, completing, and review workflows for AI agents.",
      tags: ["developer", "workflow", "api"],
      content_type: "guide",
      reading_time: 10,
      thumbnail: "/images/resources/claim-complete.png",
      created_at: ~D[2026-01-16],
      steps: [
        %{
          title: "The Task Lifecycle",
          content:
            "Tasks flow through these states:\n\n1. **Open** → Available for claiming\n2. **In Progress** → Claimed by an agent\n3. **Review** → Awaiting human approval (if needed)\n4. **Done** → Completed",
          image: nil
        },
        %{
          title: "Finding Available Tasks",
          content:
            "Use `GET /api/tasks/next` to find the next available task:\n\n```bash\ncurl -H \"Authorization: Bearer $TOKEN\" \\\n  \"$API_URL/api/tasks/next\"\n```\n\nThe API returns tasks respecting dependencies and priorities.",
          image: nil
        },
        %{
          title: "Claiming a Task",
          content:
            "Execute the before_doing hook first, then claim:\n\n```bash\ncurl -X POST -H \"Authorization: Bearer $TOKEN\" \\\n  -H \"Content-Type: application/json\" \\\n  -d '{\"identifier\": \"W1\", \"agent_name\": \"Claude\", \n       \"before_doing_result\": {\"exit_code\": 0, ...}}' \\\n  \"$API_URL/api/tasks/claim\"\n```",
          image: nil
        },
        %{
          title: "Completing a Task",
          content:
            "Execute both after_doing and before_review hooks, then complete:\n\n```bash\ncurl -X PATCH -H \"Authorization: Bearer $TOKEN\" \\\n  -d '{\"after_doing_result\": {...}, \n       \"before_review_result\": {...}, \n       \"completion_notes\": \"...\"}' \\\n  \"$API_URL/api/tasks/123/complete\"\n```",
          image: nil
        },
        %{
          title: "Review Flow",
          content:
            "If `needs_review` is true, the task enters Review status. A human reviewer approves or requests changes. Once approved, execute the after_review hook.",
          image: nil
        }
      ]
    },
    %{
      id: "debugging-hooks",
      title: "Debugging Hook Failures",
      description:
        "Troubleshoot common hook execution issues and learn best practices for reliable automation.",
      tags: ["developer", "hooks", "troubleshooting"],
      content_type: "guide",
      reading_time: 6,
      thumbnail: "/images/resources/debug-hooks.png",
      created_at: ~D[2026-01-16],
      steps: [
        %{
          title: "Common Failure Causes",
          content:
            "Hooks fail for several reasons:\n\n- **Exit code non-zero**: Tests failing, lint errors\n- **Timeout exceeded**: Hook taking too long (60-120s limits)\n- **Missing dependencies**: Commands not found\n- **Permission errors**: File access issues",
          image: nil
        },
        %{
          title: "Reading Hook Output",
          content:
            "The API returns hook output in the response:\n\n```json\n{\n  \"exit_code\": 1,\n  \"output\": \"Error: 3 tests failed...\",\n  \"duration_ms\": 5432\n}\n```\n\nUse this output to diagnose the issue.",
          image: nil
        },
        %{
          title: "Testing Hooks Locally",
          content:
            "Test your hooks manually before relying on them:\n\n```bash\nexport TASK_IDENTIFIER=\"W1\"\nexport TASK_TITLE=\"Test Task\"\nbash -c 'source .stride.md && echo $TASK_IDENTIFIER'\n```",
          image: nil
        },
        %{
          title: "Best Practices",
          content:
            "- Keep hooks fast (under 60 seconds)\n- Use set -e to fail fast on errors\n- Log meaningful output for debugging\n- Handle edge cases (empty repos, missing files)\n- Test hooks in CI before production",
          image: nil
        }
      ]
    }
  ]

  @all_tags [
    "getting-started",
    "beginner",
    "developer",
    "boards",
    "tasks",
    "workflow",
    "collaboration",
    "hooks",
    "api",
    "automation",
    "security",
    "troubleshooting"
  ]

  @doc """
  Returns all how-to guides.
  """
  def all_how_tos, do: @how_tos

  @doc """
  Returns all available tags.
  """
  def all_tags, do: @all_tags

  @doc """
  Returns the type icon mapping.
  """
  def type_icons, do: @type_icons

  @doc """
  Finds a how-to by its ID.
  Returns `{:ok, how_to}` or `:error`.
  """
  def get_how_to(id) do
    case Enum.find(@how_tos, &(&1.id == id)) do
      nil -> :error
      how_to -> {:ok, how_to}
    end
  end

  @doc """
  Returns the type icon for a content type.
  """
  def type_icon(content_type) do
    Map.get(@type_icons, content_type, "hero-document")
  end

  @doc """
  Formats a tag for display (kebab-case to Title Case).
  """
  def format_tag(tag) do
    tag
    |> String.replace("-", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @doc """
  Returns previous and next how-tos within the same tags.
  """
  def get_navigation(current_how_to) do
    # Get how-tos that share at least one tag
    primary_tag = List.first(current_how_to.tags)

    related =
      @how_tos
      |> Enum.filter(&(primary_tag in &1.tags))
      |> Enum.with_index()

    current_index =
      Enum.find_index(related, fn {how_to, _} -> how_to.id == current_how_to.id end)

    prev_how_to =
      if current_index && current_index > 0 do
        {how_to, _} = Enum.at(related, current_index - 1)
        how_to
      end

    next_how_to =
      if current_index && current_index < length(related) - 1 do
        {how_to, _} = Enum.at(related, current_index + 1)
        how_to
      end

    {prev_how_to, next_how_to}
  end
end
