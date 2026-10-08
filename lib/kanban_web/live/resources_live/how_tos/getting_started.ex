defmodule KanbanWeb.ResourcesLive.HowTos.GettingStarted do
  @moduledoc """
  Getting-started guides: creating a board, columns, the first task and working as a team.

  One of the data modules `KanbanWeb.ResourcesLive.HowToData` concatenates,
  in order, into the Resources catalog.
  """

  @doc "The guides in this group, in display order."
  def how_tos do
    [
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
            title: "Access Your Boards Dashboard",
            content:
              "After logging in, you'll automatically land on your **My Boards** dashboard. If you're navigating from elsewhere in the app, you can always return here by clicking **My Boards** in the navigation bar.",
            image: "/images/resources/guides/board-creation-step-1.png",
            image_width: 243,
            image_height: 43
          },
          %{
            title: "Click New Board",
            content:
              "Click the **New Board** button in the top right corner. You'll see two options: **New Empty Board** for a blank slate, or **New AI Optimized Board** which comes pre-configured with columns optimized for AI agent workflows.",
            image: "/images/resources/guides/board-creation-step-2.png",
            image_width: 204,
            image_height: 140
          },
          %{
            title: "Enter Board Details",
            content:
              "Give your board a descriptive name and optional description. The name should reflect the project or team that will use this board.",
            image: "/images/resources/guides/board-creation-step-3.png",
            image_width: 525,
            image_height: 305
          },
          %{
            title: "Start Using Your Board",
            content:
              "Your AI Optimized board is ready with pre-configured workflow columns (Backlog → Ready → Doing → Review → Done). To invite team members, click the **Edit Board** button and add collaborators in the board settings.",
            image: "/images/resources/guides/board-creation-step-4.png",
            image_width: 1355,
            image_height: 325
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
              "Columns represent stages in your workflow. Tasks move from left to right as they progress through different stages toward completion. Stride offers two types of boards with different column configurations."
          },
          %{
            title: "AI-Optimized Boards: Fixed Columns",
            content:
              "**AI-optimized boards** come with five pre-configured columns designed for AI agent workflows. These columns **cannot be added, removed, or renamed**:\n\n- **Backlog**: Tasks that are not yet ready to be worked on\n- **Ready**: Tasks available for AI agents to claim\n- **Doing**: Tasks currently being worked on\n- **Review**: Tasks awaiting human review\n- **Done**: Completed tasks\n\nThis fixed structure ensures consistency for AI agents working across multiple boards.",
            image: "/images/resources/guides/understanding-columns-step-2.png",
            image_width: 714,
            image_height: 317
          },
          %{
            title: "Custom Boards: Flexible Columns",
            content:
              "**Non-AI optimized boards** give you complete flexibility to design your own workflow. You can:\n\n- Create any number of columns with custom names\n- Add new columns by clicking **Add Column**\n- Reorder columns by dragging them\n- Rename or delete existing columns\n- Design workflows like **Backlog → In Progress → Testing → Complete** or any pattern that fits your team's needs",
            image: "/images/resources/guides/understanding-columns-step-3.png",
            image_width: 730,
            image_height: 180
          },
          %{
            title: "Choosing the Right Board Type",
            content:
              "When creating a board, select:\n\n- **AI Optimized Board** if you'll be working with AI agents or want a standardized agent-friendly workflow\n- **Empty Board** if you need custom columns tailored to your team's specific process\n\nNote: You cannot convert between board types after creation, so choose carefully based on your workflow needs."
          },
          %{
            title: "WIP Limits (Custom Boards Only)",
            content:
              "Only **Custom Boards** support **WIP (Work In Progress) limits** on each column. WIP limits prevent bottlenecks by restricting how many tasks can be in a column at once, keeping work flowing smoothly through your workflow.\n\nAI-Optimized Boards do not support WIP limits — their five-column structure is fixed by design so AI agents can rely on a consistent workflow.",
            images: [
              %{
                url: "/images/resources/guides/understanding-columns-step-5-1.png",
                alt: "AI-Optimized Board column settings (no WIP limit field)",
                width: 602,
                height: 340
              },
              %{
                url: "/images/resources/guides/understanding-columns-step-5-2.png",
                alt: "Custom Board column settings with the WIP limit field",
                width: 234,
                height: 77
              }
            ]
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
              "Click the <span class=\"hero-plus-circle-solid h-5 w-5 text-[var(--st-done)] inline-block\"></span> button at the bottom of any column, or use the keyboard shortcut **N** when focused on a column.",
            image: "/images/resources/guides/adding-task-step-1.png",
            image_width: 517,
            image_height: 263
          },
          %{
            title: "Enter Task Details",
            content:
              "Fill in the essential fields:\n\n- **Title**: A clear, action-oriented description\n- **Type**: Work, Defect, or Goal\n- **Priority**: Low, Medium, High, or Critical\n- **Description**: Detailed context and requirements",
            image: "/images/resources/guides/adding-task-step-2.png",
            image_width: 542,
            image_height: 586
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
            image: "/images/resources/guides/adding-task-step-4.png",
            image_width: 263,
            image_height: 256
          }
        ]
      },
      %{
        id: "inviting-team-members",
        title: "Adding Team Members to Your Board",
        description:
          "Learn how to add collaborators to your board and set their access permissions.",
        tags: ["getting-started", "beginner", "collaboration"],
        content_type: "guide",
        reading_time: 2,
        thumbnail: "/images/resources/invite-members.png",
        created_at: ~D[2026-01-15],
        steps: [
          %{
            title: "Access Board Settings",
            content:
              "From your board view, click the **Edit board** button in the top right corner to access board management options.\n\n**Important:** Users must already have a Stride account to be added to your board. Team members need to register at Stride before you can add them as collaborators.",
            image: "/images/resources/guides/inviting-members-step-1.png",
            image_width: 1387,
            image_height: 304
          },
          %{
            title: "Search for Users",
            content:
              "In the board settings form, locate the **Board Users** section. Use the search field to find registered Stride users by their email address or name. Select the user from the search results.",
            image: "/images/resources/guides/inviting-members-step-2.png",
            image_width: 603,
            image_height: 369
          },
          %{
            title: "Set Permission Level",
            content:
              "After selecting a user, choose their permission level:\n\n- **Can View**: Read-only access to view tasks and board\n- **Can Edit**: Can create, edit, and manage tasks\n- **Owner**: Full control including board settings and user management\n\nClick **Add User** to complete the process. The user will immediately have access to your board.",
            image: "/images/resources/guides/inviting-members-step-3.png",
            image_width: 603,
            image_height: 298
          }
        ]
      },
      %{
        id: "using-stride-with-a-team",
        title: "Using Stride With a Team",
        description:
          "Coordinate multiple developers and their AI agents on the same board by assigning goals to specific people.",
        tags: ["collaboration", "best-practices", "workflow", "ai-agents"],
        content_type: "guide",
        reading_time: 5,
        thumbnail: "/images/resources/team-workflow.png",
        created_at: ~D[2026-05-09],
        steps: [
          %{
            title: "Why Goal Assignment Matters for Teams",
            content:
              "When multiple developers run AI agents against the same Stride board, they share a single pool of available work. Without coordination, one developer's agent can claim a task that another developer was about to work on — leading to merge conflicts, duplicated effort, and verbal coordination overhead Stride was supposed to eliminate.\n\nAssigning a goal to a specific developer turns that goal into **their** lane of work:\n\n- Only their agents can claim tasks under that goal\n- Any new child task added to the goal automatically inherits the assignment\n- Other team members' agents skip past the goal entirely when polling for work\n\nThe rest of this guide walks through how to set this up and use it day to day.",
            image: nil
          },
          %{
            title: "Plan the Work as Goals, Not Flat Tasks",
            content:
              "The team workflow only works if your work is organized into **goals with children**, not as a flat list of independent tasks. Before assigning anything, make sure each major initiative is structured as a goal:\n\n- **Goal**: A multi-task initiative (e.g. \"Billing rewrite\", \"Onboarding flow\", \"Search performance\")\n- **Child tasks**: The individual work items (W-tasks for features, D-tasks for defects)\n\nA good rule of thumb: if two developers could reasonably own different *parts* of the same effort, those parts should be separate goals. Assignment happens at the goal level, so the goal boundary is also the ownership boundary.",
            image: nil
          },
          %{
            title: "Assign Each Goal to a Developer",
            content:
              "Open the goal in the board view and set the **Assigned To** field to the developer who will own it. Save the change.\n\nWhen you save:\n\n- The assignment cascades atomically to every non-completed child task under the goal\n- A flash message confirms how many children were updated (\"3 child tasks were also updated.\")\n- Connected boards refresh in real time so other team members see the change immediately\n- Completed children are intentionally not touched — their assignment is part of the historical record\n\nRepeat for each major goal on the board. Two developers can each own multiple goals; one developer can own everything; an unassigned goal remains a shared pool that anyone can pick from.",
            image: nil
          },
          %{
            title: "Run Agents Per Developer",
            content:
              "Each developer runs their own AI agent (Claude Code, Copilot, Cursor, etc.) authenticated against Stride with their own user identity. When the agent calls `GET /api/tasks/next`, Stride filters the queue automatically:\n\n- Tasks assigned to the calling user — included\n- Unassigned tasks — included (shared pool)\n- Tasks assigned to other users — excluded\n\nNo manual filtering, no \"please don't take this one\" notes, no daily standup carve-up of the backlog. The assignment graph IS the coordination protocol, and Stride enforces it on every claim.\n\nIf an agent tries to claim a specific task assigned to another user (for example, by identifier), the API returns **403 Forbidden** with `{\"error\": \"This task is assigned to a different user\"}`. The recommended remediation is to skip that task and call `GET /api/tasks/next` again — the queue endpoint already filters correctly, so the 403 should be rare in practice.",
            image: nil
          },
          %{
            title: "Adding New Tasks Mid-Flight",
            content:
              "When you add a new child task to an already-assigned goal, the new task automatically inherits the goal's `assigned_to_id`. You don't have to remember to set it. This applies whether you create the task through the UI, the API, or via a batch goal creation.\n\nIf you genuinely want a new child to be unassigned (so anyone's agent can pick it up), explicitly set its assignee to **None** when creating it. Explicit values always win over inheritance — including explicit \"unassigned.\"\n\nThis means the team can keep adding work to in-flight goals without re-opening the coordination problem each time. The invariant — \"the goal owner owns the goal's work\" — holds even as the goal grows.",
            image: nil
          },
          %{
            title: "Handing a Goal Off",
            content:
              "When a developer rotates off a goal — illness, vacation, end-of-sprint reshuffle, or just realizing someone else has more context — change the goal's **Assigned To** field to the new owner and save.\n\nIn one atomic operation:\n\n- The goal moves to the new owner\n- Every non-completed child moves with it\n- Per-task assignment history rows record the handoff\n- The previous owner's agents stop seeing the work on their next poll\n- The new owner's agents pick it up on their next poll\n\nNo task-by-task reassignment. No risk of orphaned children stuck on the previous owner. Setting the goal back to **Unassigned** does the same thing in reverse — every non-completed child moves back to the shared pool.",
            image: nil
          },
          %{
            title: "Best Practices for Team Workflows",
            content:
              "**Keep goals scoped to one owner at a time.** If two developers are actively working on the same goal, that's a sign the goal is too big — split it into separate goals so each can be owned independently.\n\n**Use the unassigned pool for shared backlog work.** Bug fixes, small enhancements, and exploratory tasks that any team member could pick up belong in unassigned goals (or as flat unassigned tasks). The assignment system is opt-in per goal — you don't have to assign everything.\n\n**Make assignment changes visible.** When you reassign or hand off a goal, mention it in your team chat. The system handles the technical handoff automatically, but humans still benefit from knowing who's responsible for what.\n\n**Review the assignment graph regularly.** During retros or planning, glance at who owns which goals on the board. Imbalances (one developer owning everything, or critical goals unassigned) are easy to spot and easy to rebalance with a single field change per goal.",
            image: nil
          }
        ]
      }
    ]
  end
end
