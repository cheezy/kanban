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
        created_at: ~D[2026-01-15],
        steps: [
          %{
            title: "Access Your Boards Dashboard",
            content:
              "After you sign in, Stride opens your **Boards** page. It lists your boards and the boards shared with you. To come back to it from anywhere, click **Boards** in the sidebar. On a phone, tap the menu button at the top left to open the sidebar first.",
            image: "/images/resources/guides/board-creation-step-1.png",
            image_width: 151,
            image_height: 270
          },
          %{
            title: "Choose a Board Type",
            content:
              "Click **New board** at the top of the page, or use the **New board** card after your boards. There are two kinds of board:\n\n- **AI Optimized** (**New AI Optimized Board** in the menu) gives you five fixed columns built for AI agents.\n- **Empty Board** (**New Empty Board** in the menu) gives you a board with no columns, so you can add your own.\n\nYou can't change a board's type later, so pick the one that fits how you work.",
            image: "/images/resources/guides/board-creation-step-2.png",
            image_width: 820,
            image_height: 312
          },
          %{
            title: "Enter Board Details",
            content:
              "The **New Board** form opens. Type a **Name** for the board. It must be 5 to 50 characters long. You can add a **Description** too, up to 255 characters. Click **Save Board** to create the board.",
            image: "/images/resources/guides/board-creation-step-3.png",
            image_width: 680,
            image_height: 372
          },
          %{
            title: "Start Using Your Board",
            content:
              "Stride opens your new board. An AI Optimized board starts with five columns: Backlog, Ready, Doing, Review and Done. An Empty board starts with no columns, so click **Create your first column** to add one.\n\nUnder the board name is a row of tabs. To bring in your team, open the **Members** tab. [Adding Team Members to Your Board](/resources/inviting-team-members) shows how.",
            image: "/images/resources/guides/board-creation-step-4.png",
            image_width: 1237,
            image_height: 452
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
        created_at: ~D[2026-01-15],
        steps: [
          %{
            title: "What Are Columns?",
            content:
              "Columns are the stages of your workflow. Tasks move from left to right as the work moves toward done. Stride has two kinds of board, and each handles columns in its own way."
          },
          %{
            title: "AI-Optimized Boards: Fixed Columns",
            content:
              "An AI Optimized board has five columns that are set for you. You can't add, rename, delete or reorder them:\n\n- **Backlog**: tasks that aren't ready to work on yet\n- **Ready**: tasks that agents can claim\n- **Doing**: tasks someone is working on\n- **Review**: finished work waiting for a person to review it\n- **Done**: finished tasks\n\nAgents only claim work and defect tasks from **Ready**. Every AI Optimized board has the same columns, so an agent can work on any of them the same way.",
            image: "/images/resources/guides/understanding-columns-step-2.png",
            image_width: 1237,
            image_height: 490
          },
          %{
            title: "Custom Boards: Flexible Columns",
            content:
              "An Empty board starts with no columns, and you design the workflow. If you own the board, you can:\n\n- Click **New column** to add a column. Give it a **Name** and click **Save Column**.\n- Drag a column by its handle to move it.\n- Hover over a column header and click the pencil to rename it, or the trash can to delete it.\n\nDeleting a column also deletes every task in it. A custom workflow might be To Do, In Progress, In Review and Published.",
            image: "/images/resources/guides/understanding-columns-step-3.png",
            image_width: 1218,
            image_height: 276
          },
          %{
            title: "Choosing the Right Board Type",
            content:
              "You choose the type when you create the board:\n\n- **AI Optimized** if AI agents will work on the board, or you want the standard agent workflow\n- **Empty Board** if your team needs its own columns\n\nYou can't change a board's type after you create it, so choose with care."
          },
          %{
            title: "WIP Limits (Custom Boards Only)",
            content:
              "A WIP (work in progress) limit caps how many tasks a column can hold. It stops work piling up in one stage. Only Empty boards have WIP limits. You can't edit an AI Optimized board's columns, so there's nowhere to set one.\n\nTo set a limit, edit the column and enter a number in **WIP Limit**. Use 0 for no limit. The column header then shows the count and the limit, for example 3/3. Goals don't count toward it.\n\nWhen a column is full, its **Add Task** button is hidden, and Stride won't let you drag another task into it.",
            images: [
              %{
                url: "/images/resources/guides/understanding-columns-step-5-1.png",
                alt: "The form for the In Progress column, with WIP Limit set to 3",
                width: 697,
                height: 412
              },
              %{
                url: "/images/resources/guides/understanding-columns-step-5-2.png",
                alt: "The In Progress column header showing 3/3, a full column",
                width: 300,
                height: 262
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
        created_at: ~D[2026-01-15],
        steps: [
          %{
            title: "Open the Task Form",
            content:
              "Click the plus button at the right end of the column header. Hover over it to see its label, **Add Task**. The button only appears on boards you can edit, and it's hidden while a column is at its WIP limit.",
            image: "/images/resources/guides/adding-task-step-1.png",
            image_width: 560,
            image_height: 160
          },
          %{
            title: "Enter Task Details",
            content:
              "The **New Task** form opens. Fill in these fields:\n\n- **Title**: a short name for the work. It's required.\n- **Description**: what needs doing and why.\n- **Type**: Work, Defect or Goal. New tasks start as Work.\n- **Priority**: Low, Medium, High or Critical. New tasks start as Medium.\n- **Parent Goal**: the goal this task belongs to, if any.\n- **Assigned To**: the person who owns the task, or **Unassigned**.\n\nThe form also has **Status** and **Column**. They start as Open and the column you clicked, so you can leave them.",
            image: "/images/resources/guides/adding-task-step-2.png",
            image_width: 826,
            image_height: 800
          },
          %{
            title: "Add Acceptance Criteria",
            content:
              "Use the **Acceptance Criteria** field to say what done looks like. Good criteria are specific and easy to test. They help people and AI agents know exactly what's expected. If you don't see the field, the board owner has turned it off in **Settings**.",
            image: nil
          },
          %{
            title: "Save and Start Working",
            content:
              "Click **Save Task**. Stride adds the task to the column.\n\nOn an AI Optimized board, agents only claim tasks from the **Ready** column. If you added the task to **Backlog**, drag it to **Ready** when it's ready for work.",
            image: "/images/resources/guides/adding-task-step-4.png",
            image_width: 560,
            image_height: 225
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
        reading_time: 3,
        created_at: ~D[2026-01-15],
        steps: [
          %{
            title: "Open the Members Tab",
            content:
              "Open your board. Under the board name is a row of tabs. Click **Members**. Only the board owner can add or remove people. Anyone else who opens the tab is sent back to the board.",
            image: "/images/resources/guides/inviting-members-step-1.png",
            image_width: 1218,
            image_height: 200
          },
          %{
            title: "Search by Email",
            content:
              "The **Manage members** window opens. Type the person's full email address and click **Search**. Search only matches a whole email address, so a name or part of an address won't find anyone.\n\nIf they have a Stride account, their name and email appear below the search box.",
            image: "/images/resources/guides/inviting-members-step-2.png",
            image_width: 697,
            image_height: 350
          },
          %{
            title: "Choose Their Access",
            content:
              "Pick how much they can do:\n\n- **Add as Read Only**: they can see the board and its tasks, but can't change anything.\n- **Add with Edit Access**: they can create, edit and move tasks, add goals and manage labels.\n\nThey're added straight away and appear in the list of current users. Only the owner can manage members, columns, board settings and integrations. To change someone's access, click **Remove** and add them again.",
            image: "/images/resources/guides/inviting-members-step-3.png",
            image_width: 697,
            image_height: 420
          },
          %{
            title: "Invite Someone Without an Account",
            content:
              "If no account uses that email, Stride says so and offers an invitation. Click **Invite as Read Only** or **Invite with Edit Access**. Stride emails them a link that works for 7 days. They create an account or sign in, then accept the invitation to join the board.\n\nOn a board in an organization, only an org-admin can invite by email, and you can only add people who are in that organization.",
            image: "/images/resources/guides/inviting-team-members-step-4.png",
            image_width: 697,
            image_height: 640
          },
          %{
            title: "Free Board Limits",
            content:
              "When Stride's plans are switched on, a free board holds up to 3 people. The owner counts as one of them, and so do read-only members and disabled accounts. The members window then shows how many places are used, for example 2 of 3 people.\n\nWhen the board is full, the search box and the add and invite buttons are turned off. To add more people, move the board into an organization. Boards in an organization have no member limit. Click **Get Stride for your organization** to contact us. When plans are switched off, free boards have no member limit either."
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
        created_at: ~D[2026-05-09],
        steps: [
          %{
            title: "Why Goal Assignment Matters for Teams",
            content:
              "When several developers run AI agents on one board, the agents share one pool of work. Without a plan, one person's agent can claim a task someone else meant to do. That leads to merge conflicts and wasted effort.\n\nAssign a goal to one developer to make it their lane of work:\n\n- Only their agents can claim the goal's tasks.\n- Child tasks that agents or the API add to the goal get the same assignee.\n- Other developers' agents skip those tasks when they ask for work.\n\nThe rest of this guide shows how to set this up.",
            image: nil
          },
          %{
            title: "Plan the Work as Goals, Not Flat Tasks",
            content:
              "Team assignment works best when work is grouped into goals with child tasks. Before you assign anything, make each big piece of work a goal:\n\n- A goal is a larger piece of work, such as Billing rewrite or Search performance.\n- Child tasks are the work items under it: work tasks (W) and defects (D).\n\nTo make a goal, click **New goal** at the top of the board. To put a task under a goal, pick the goal in the task's **Parent Goal** field. The goal's card shows how many of its children are done, and each child shows the goal it belongs to.\n\nIf two developers could each own a different part of the work, make each part its own goal. You assign at the goal level, so the goal is also the line of ownership.",
            image: "/images/resources/guides/using-stride-with-a-team-step-2.png",
            image_width: 548,
            image_height: 322
          },
          %{
            title: "Assign Each Goal to a Developer",
            content:
              "Hover over the goal's card and click the pencil to open the **Edit Task** form. Set **Assigned To** to the developer who will own the goal, then click **Save Task**. Read-only members aren't in the list.\n\nWhen you save:\n\n- Every unfinished child task gets the same assignee, all in one step.\n- A message says how many children changed, for example: Task updated successfully. 3 child tasks were also updated.\n- People who have the board open see the change without reloading.\n- Finished children keep their old assignee, so the record of who did them stays the same.\n\nDo this for each goal. One developer can own many goals. A goal left as **Unassigned** stays in the shared pool.",
            image: "/images/resources/guides/using-stride-with-a-team-step-3.png",
            image_width: 1024,
            image_height: 205
          },
          %{
            title: "Run Agents Per Developer",
            content:
              "Each developer runs their own AI agent, such as Claude Code, Copilot or Cursor. Each agent uses an API token its developer made on the board's **Tokens** tab. When the agent calls `GET /api/tasks/next`, Stride filters the list for that developer:\n\n- Tasks assigned to them are included.\n- Unassigned tasks are included. This is the shared pool.\n- Tasks assigned to someone else are left out.\n\nNo one needs to leave notes asking others not to take a task. The assignments are how the team coordinates, and Stride checks them on every claim.\n\nIf an agent tries to claim someone else's task, for example by its identifier, Stride refuses with a 403 error. The message says the task is assigned to a different user and only that user can claim it. The agent should skip the task and call `GET /api/tasks/next` again. That endpoint already leaves such tasks out, so the error is rare.",
            image: nil
          },
          %{
            title: "Adding New Tasks Mid-Flight",
            content:
              "When an agent or the API adds a child task to an assigned goal, the new task gets the goal's assignee. This includes goals created in one batch with their tasks, so you don't have to set it.\n\nThe task form is different. It always sends its own **Assigned To** value. When you add a child in the form, set **Assigned To** to the goal's owner. Leave it as **Unassigned** if anyone's agent may pick it up.\n\nAn assignee you choose always wins over the goal's. If the goal's owner has a disabled account, the new task starts unassigned.",
            image: nil
          },
          %{
            title: "Handing a Goal Off",
            content:
              "When a developer moves off a goal, for a holiday or a new sprint, open the goal's **Edit Task** form. Change **Assigned To** to the new owner and click **Save Task**.\n\nIn one step:\n\n- The goal moves to the new owner.\n- Every unfinished child task moves with it.\n- Each task's history records the change.\n- The old owner's agents stop seeing the work the next time they ask for tasks.\n- The new owner's agents pick it up the next time they ask.\n\nYou don't have to reassign tasks one by one. Setting the goal back to **Unassigned** works the same way: every unfinished child goes back to the shared pool.",
            image: nil
          },
          %{
            title: "Best Practices for Team Workflows",
            content:
              "- Give each goal one owner at a time. If two developers work on the same goal, it's too big. Split it into two goals.\n- Use the unassigned pool for shared work. Small fixes and tasks anyone could do belong in unassigned goals, or as unassigned tasks. You don't have to assign everything.\n- Tell the team when you hand a goal off. Stride moves the work, but people still need to know who owns what.\n- Check who owns what during planning or retros. Look for one developer with too many goals, or important goals with no owner. One change to **Assigned To** fixes each one.",
            image: nil
          }
        ]
      }
    ]
  end
end
