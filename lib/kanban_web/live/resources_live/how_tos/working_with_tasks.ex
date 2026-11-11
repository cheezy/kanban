defmodule KanbanWeb.ResourcesLive.HowTos.WorkingWithTasks do
  @moduledoc """
  Guides for writing, monitoring, reviewing and organizing tasks, and for
  grouping them into goals.

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
        reading_time: 6,
        created_at: ~D[2026-01-17],
        steps: [
          %{
            title: "Start with a Clear Title",
            content:
              "The **Title** says what needs to be done. Start it with a verb such as \"Add\", \"Create\", \"Fix\" or \"Update\".\n\nGood examples:\n\n- \"Add user authentication to the login page\"\n- \"Fix the broken image upload feature\"\n- \"Create a dashboard for viewing statistics\"\n\nAvoid vague titles like these:\n\n- \"Work on login\" (too vague)\n- \"Bug\" (doesn't describe the problem)",
            image: nil
          },
          %{
            title: "Write a Detailed Description",
            content:
              "The **Description** is where you explain why the task matters and what the result should be. A good description includes:\n\n- The problem you're solving\n- Who benefits from the change\n- Any background the agent needs\n- Links to related documents or discussions\n\nThe more context you give, the better the agent understands what you want.",
            image: nil
          },
          %{
            title: "Define Clear Acceptance Criteria",
            content:
              "The acceptance criteria tell the agent exactly what \"done\" looks like. Put one criterion on each line of the **Acceptance Criteria** field, written as a simple statement someone can check:\n\n- \"Users can log in with email and password\"\n- \"An error message shows when login fails\"\n- \"The session survives a browser refresh\"\n\nEach line shows as a checklist item in the task's details and in the Review queue. When the agent reviews its own work, it marks each item met or not, and you check those marks when you review.",
            image: nil
          },
          %{
            title: "Turn On the Fields Agents Use",
            content:
              "On a new board the task form shows the everyday fields, such as **Title**, **Description**, **Acceptance Criteria**, **Priority**, **Assigned To**, **Dependencies** and **Human Task**. Tick **Human Task** for work a person must do, and agents will leave it alone.\n\nAgents do their best work when a task also says which files to read, how to test the change and what to avoid. Those fields are hidden until the board owner turns them on: open the board's **Settings** tab and, under **Field visibility**, switch on the ones you want. Each switch takes effect at once. The ones agents rely on most are:\n\n- **Key Files**: the files to read or change first\n- **Testing Strategy**: the tests that prove the change works\n- **Verification Steps**: the commands or checks to run when it's finished\n- **Pitfalls**: the mistakes to avoid\n\nEvery board member can open **Settings**, but only the owner can change **Field visibility**.",
            image: nil
          },
          %{
            title: "Ask for a Review When It Matters",
            content:
              "On an AI Optimized board the task form has a **Needs Review** checkbox. When it's ticked, the finished task waits in the **Review** column until a person approves it. When it isn't, the task goes straight to **Done** as soon as the agent finishes.\n\nTick it for work you want to see before it counts as done. See [Reviewing Completed Work](/resources/reviewing-completed-work) for what happens next.",
            image: nil
          },
          %{
            title: "Choose the Right Priority and Complexity",
            content:
              "**Priority** decides which Ready task an agent picks up first. Complexity is your estimate of the effort: roughly under 1 hour for a small task, 1 to 2 hours for a medium one and more than 2 hours for a large one. Nothing enforces these times.\n\nSee [Using Complexity and Priority Effectively](/resources/using-complexity-priority) for how agents use them.",
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
        reading_time: 5,
        created_at: ~D[2026-01-17],
        steps: [
          %{
            title: "Understanding Task Columns",
            content:
              "Tasks move through the columns of an AI Optimized board as they progress:\n\n- **Backlog**: ideas and planned work that agents can't take yet\n- **Ready**: tasks waiting for an agent to claim them\n- **Doing**: tasks an agent is working on\n- **Review**: finished work waiting for a person's approval\n- **Done**: finished and approved tasks\n\nAgents only take tasks from **Ready**. To release a task from the Backlog, drag it to Ready or click the **Move to Ready** arrow on its card. Only tasks with **Needs Review** ticked stop in Review; the rest go straight to Done.",
            image: nil
          },
          %{
            title: "Checking Who's Working on What",
            content:
              "When an agent claims a task, the task moves to **Doing** and is assigned to the person whose API token the agent uses. The card shows that person's initials in its top corner. It doesn't show the agent's name or how long the task has been in progress.\n\nTo find out more, open the task. The panel on the right shows the person under **Author** and the time of the claim under **Claimed**.",
            image: nil
          },
          %{
            title: "When a Claim Runs Out",
            content:
              "A claim lasts 60 minutes. When it runs out, nothing moves: the task stays in **Doing** and stays assigned, and the person whose agent claimed it gets a notification. When Stride's plans are switched on, a free board sends no notifications.\n\nIf the agent has stopped and you want another one to take the task, drag the card back to **Ready**. The task stays assigned, and agents only take tasks that are unassigned or assigned to their own person, so if the next agent uses someone else's API token, click **Edit task** and set **Assigned To** to **Unassigned**. If tasks often run out of time, split them into smaller ones.",
            image: nil
          },
          %{
            title: "Viewing Task Details",
            content:
              "Click any task card to open its details. You'll see the description and, where they've been filled in:\n\n- **Acceptance criteria**, as a checklist\n- **Dependencies**, the tasks it waits for\n- **Completion**, the agent's summary and notes once it's finished\n- **Changed files**, with the diff for each file\n- **History**, every move and change\n\nThe panel on the right shows **Status**, **Column**, **Priority** and the dates, with an **Edit task** button. A task waiting in Review keeps the status **Doing**; its **Column** says Review.",
            image: "/images/resources/guides/monitoring-task-progress-step-4.png",
            image_width: 988,
            image_height: 536
          },
          %{
            title: "Using Filters to Focus",
            content:
              "The bar above the columns narrows the board down:\n\n- The **Search title or ID** box finds tasks by words in the title or by identifier, such as W12\n- **All types**, **All priorities**, **All assignees** and **All labels** each limit the board to one choice. The labels filter appears once the board has labels\n- **Clear filters** shows while any filter is on and turns them all off\n\nThere's no status filter: the columns already show each task's status. While a filter is on you can't drag cards to reorder them.\n\nPress `/` to jump to the search box and `?` to see the **Keyboard shortcuts**.",
            image: "/images/resources/guides/monitoring-task-progress-step-5.png",
            image_width: 1000,
            image_height: 313
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
        reading_time: 6,
        created_at: ~D[2026-01-17],
        steps: [
          %{
            title: "When to Review",
            content:
              "A task with **Needs Review** ticked moves to the **Review** column when the agent finishes it. The board owner and members with edit access each get a notification, and an email unless they've turned **Review requests** off in their notification settings. When Stride's plans are switched on, a free board sends no notifications.\n\nReview is your chance to:\n\n- Check the work meets the acceptance criteria\n- Catch problems before the task counts as done\n- Give the agent specific feedback\n\nOnly the board owner and members with edit access can approve work or request changes.",
            image: nil
          },
          %{
            title: "Open the Review Queue",
            content:
              "Click **Review queue** in the sidebar. It lists every task waiting for review on all the boards you can see, oldest first, and opens the first one. The heading says how many tasks are waiting, from how many agents, and how long the oldest has waited.\n\nClick a task on the left to see it on the right. When nothing is waiting, the page says so.",
            image: "/images/resources/guides/reviewing-completed-work-step-2.png",
            image_width: 1200,
            image_height: 750
          },
          %{
            title: "What to Check",
            content:
              "Work down the task from the top:\n\n- The row under the title shows **Acceptance**, **Testing strategy**, **Patterns** and **Pitfalls**: the results of the agent's own review of its work. The **Approved** badge next to the title is that agent review too, not your decision\n- **Completion summary** and **Completion notes** say what the agent did and what it noticed\n- **Issues** lists any problems the agent's review found\n- The **Acceptance criteria** checklist shows each criterion, with the evidence the agent gave\n- **Review checks** shows how the testing, patterns and pitfalls checks went\n- **Changed files** lists every file the agent changed. Click a file to see its diff, and click it again to close it\n\nIf a file list says the diff wasn't uploaded, click **Re-fetch diff**.",
            image: "/images/resources/guides/reviewing-completed-work-step-3.png",
            image_width: 820,
            image_height: 360
          },
          %{
            title: "Approving Work",
            content:
              "If the work meets your requirements:\n\n1. Click **Approve** at the top of the task\n2. The task moves to **Done** straight away\n\nThere's no confirmation and no notes field. A task that depends on this one unblocks once all its dependencies are finished, and the person whose agent did the work gets a notification unless they approved it themselves. The agent finds out the next time it checks the task.",
            image: "/images/resources/guides/reviewing-completed-work-step-4.png",
            image_width: 856,
            image_height: 194
          },
          %{
            title: "Requesting Changes",
            content:
              "If the work needs more:\n\n1. Click **Request changes**\n2. Write what needs to be different in **Notes for the agent**. Notes are required\n3. Click **Send request**, or **Cancel** to go back\n\nThe task stays in the Review column with its card marked \"changes requested\", and it leaves your queue. The person whose agent did the work gets your notes in a notification, unless you are that person, and the agent moves the task back to **Doing** when it picks them up.\n\nGood feedback is specific: say what's wrong, where, and what done looks like.",
            image: "/images/resources/guides/reviewing-completed-work-step-5.png",
            image_width: 856,
            image_height: 244
          },
          %{
            title: "Recording a Decision on the Task Itself",
            content:
              "You can also record a review from the task form. Open the task, click **Edit task**, and find the **Review Queue** section. Choose **Approved**, **Changes Requested** or **Rejected** under **Review Status**, add **Review Notes**, and click **Save Task**. This is the only way to reject a task.\n\nSaving the form doesn't move the task. It stays in Review until the agent checks it, and the task's details show the decision under **Review status**.",
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
        created_at: ~D[2026-01-17],
        steps: [
          %{
            title: "Understanding Dependencies",
            content:
              "Dependencies set the order tasks are done in. If Task B depends on Task A, Task A must be finished before an agent can claim Task B.\n\nWhile any of its dependencies is unfinished, a task is blocked: agents aren't offered it, even in Ready. It unblocks by itself when its last dependency is completed.\n\nThis stops agents from:\n\n- Starting work before what it needs is done\n- Making clashing changes to the same code at the same time\n- Building on unfinished work",
            image: nil
          },
          %{
            title: "When to Use Dependencies",
            content:
              "Add a dependency when:\n\n- One task builds on another's work\n- There's a natural sequence, such as design, then build, then test\n- A database change must land before the code that uses it\n\nAgents already skip a Ready task whose key files overlap work in Doing or Review, so you don't need a dependency just to keep two tasks apart. Only add one when the order matters.",
            image: nil
          },
          %{
            title: "Adding Dependencies",
            content:
              "Open the task form with the + button at the top of a column or with **Edit task**. The **Dependencies** section is always shown:\n\n1. Click **Add Dependency** to add a row\n2. Type the identifier of the task that must finish first, such as W12. Repeat for each dependency, or click **Remove** to delete a row\n3. Click **Save Task**\n\nA dependency must be a task on the same board. Stride refuses a task that depends on itself or a loop of tasks that depend on each other.",
            image: nil
          },
          %{
            title: "Seeing Dependencies on the Board",
            content:
              "A card with dependencies shows a link icon with the number of tasks it depends on. A blocked card also shows a **Blocked** icon.\n\nOpen the task to see its **Dependencies** listed by identifier.",
            image: nil
          },
          %{
            title: "Dependency Best Practices",
            content:
              "Best practices:\n\n- Keep chains short: long chains slow work down\n- Group related work into a goal with the **New goal** button, as [Working With Goals](/resources/working-with-goals) explains\n- Remove dependencies that are no longer needed",
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
        reading_time: 4,
        created_at: ~D[2026-01-17],
        steps: [
          %{
            title: "Understanding Complexity",
            content:
              "**Complexity** is your estimate of how much effort a task needs:\n\n- **Small**: under 1 hour, usually one file\n- **Medium**: 1 to 2 hours, a few files\n- **Large**: more than 2 hours, several parts of the code\n\nThese times are a rough guide, and nothing enforces them. A task bigger than Large is better split into a goal with smaller tasks.\n\nThe field is hidden on a new board. The board owner turns it on with **Complexity & Scope** under **Field visibility** in the board's **Settings**.",
            image: nil
          },
          %{
            title: "Setting Priority Right",
            content:
              "**Priority** is always on the task form, and new tasks start at **Medium**:\n\n- **Critical**: drop everything, such as a security issue or a production bug\n- **High**: important work that should happen soon\n- **Medium**: normal work\n- **Low**: nice to have, done when there's time",
            image: nil
          },
          %{
            title: "How Agents Pick the Next Task",
            content:
              "When an agent asks for work, Stride looks only at the **Ready** column. It offers the highest priority task first and, among tasks with the same priority, the one nearest the top of the column.\n\nIt skips goals, blocked tasks, tasks marked **Human Task**, tasks assigned to someone else, tasks whose key files overlap work already in Doing or Review. When the agent's API token lists the agent's skills, it also skips tasks that need a skill the agent doesn't have.\n\nComplexity doesn't change the order.",
            image: nil
          },
          %{
            title: "Balancing Complexity and Priority",
            content:
              "Consider both together:\n\n- High priority and small: a quick win, do it now\n- High priority and large: important, but plan it and think about splitting it\n- Low priority and small: fills the gaps between bigger tasks\n- Low priority and large: may never get done, so ask whether it's needed\n\nA large task can take longer than a claim's 60 minutes, which is another reason to split it.",
            image: nil
          },
          %{
            title: "Adjusting Over Time",
            content:
              "Revisit complexity and priority as work progresses:\n\n- Raise the priority when something becomes urgent\n- Drag tasks within Ready to change the order of tasks with the same priority\n- Correct the complexity when an estimate was wrong\n- Lower the priority of tasks that matter less now\n\nKeep the board matching reality.",
            image: nil
          }
        ]
      },
      %{
        id: "working-with-goals",
        title: "Working With Goals",
        description:
          "Learn how goals group related tasks, how their progress shows on the board, and what happens when the last task finishes.",
        tags: ["best-practices", "tasks", "workflow"],
        content_type: "guide",
        reading_time: 6,
        created_at: ~D[2026-11-10],
        steps: [
          %{
            title: "What a Goal Is",
            content:
              "A goal groups related tasks into one larger piece of work, such as a feature that takes several tasks to build. Its identifier starts with G, as in G1, and it holds work tasks and defects.\n\nGoals have two levels and no more:\n\n- A goal cannot contain another goal. Stride refuses to save a goal that has a **Parent Goal**\n- A task inside a goal can't hold tasks of its own\n\nAgents never claim a goal itself. They claim its tasks, and the goal follows them across the board.",
            image: nil
          },
          %{
            title: "Creating a Goal",
            content:
              "Click **New goal** at the top of the board. You see it if you own the board or have modify access. It opens the task form with **Type** already set to **Goal**:\n\n- Give the goal a **Title**, and a **Description** that says why the work matters\n- Set its **Priority**, and **Assigned To** if one person owns it\n- Leave **Parent Goal** at **No parent goal**\n- **Column** starts at the board's first column, which is **Backlog** on an AI-optimized board\n\nClick **Save Task**.\n\nAgents create a goal and its tasks together, in one call to `POST /api/tasks/batch`.",
            image: "/images/resources/guides/working-with-goals-step-2.png",
            image_width: 1072,
            image_height: 731
          },
          %{
            title: "Adding Tasks to a Goal",
            content:
              "A goal's tasks are ordinary work tasks and defects with the goal picked in **Parent Goal**. The list shows each goal on the board that isn't archived, by identifier and title, such as \"G1 - Saved payment methods\".\n\n- For a new task, click the + at the top of a column, pick the goal in **Parent Goal** and click **Save Task**\n- For an existing task, open it with **Edit task**, pick the goal and click **Save Task**\n- To take a task out of its goal, set **Parent Goal** back to **No parent goal**\n\nThe form doesn't copy the goal's assignee, so pick one in **Assigned To** if the task needs it.",
            image: nil
          },
          %{
            title: "The Goal Card",
            content:
              "A goal shows on the board as a card marked **GOAL**, with its title, priority, its description, and a progress bar such as \"1/3 children complete · 33%\". Progress counts the tasks marked completed, out of all of the goal's tasks that aren't archived. Each of the goal's tasks names the goal at the bottom of its own card.\n\nA goal's column follows its tasks. It sits in the leftmost column that holds one of them, and a goal with no tasks stays in the column it was created in.\n\nWhen a goal in **Backlog** has tasks in **Backlog** too, its card shows **Promote children to Ready**. Click it to move the goal and those tasks to **Ready**, where agents can claim them.\n\nClick the card to open the goal's page.",
            image: "/images/resources/guides/working-with-goals-step-4.png",
            image_width: 568,
            image_height: 330
          },
          %{
            title: "The Goal Page",
            content:
              "The goal page lives at `/boards/:id/goals/:goal_id`. Members of the board can open it.\n\n- The header shows how many of the goal's tasks are complete, such as \"1 of 3 complete\", how many are in each column, and **Working on it** shows the people and agents involved\n- **Hierarchy** lists the goal's tasks, grouped by column. A goal with no tasks says \"This goal has no children yet.\"\n- **Progress** and **Time** on the right sum up how it's going\n- **History** records changes to the goal itself, such as **Assigned to**\n\n**Back to Board** returns to the board. [Planning With Targets](/resources/planning-with-targets) shows how the page fits with the target a goal belongs to.",
            image: "/images/resources/guides/working-with-goals-step-5.png",
            image_width: 1085,
            image_height: 682
          },
          %{
            title: "Assigning a Goal",
            content:
              "The goal page has no assign control. To assign a goal, click the pencil icon on its card to open **Edit task**, pick someone in **Assigned To** and click **Save Task**.\n\nEvery task in the goal that isn't completed gets the same assignee in the same step, and completed tasks keep theirs. [Using Stride With a Team](/resources/using-stride-with-a-team) covers handing a goal to someone else.",
            image: nil
          },
          %{
            title: "When a Goal Is Done",
            content:
              "A goal finishes on its own. Once every task in it that isn't archived has reached **Done**, the goal moves to **Done** too. If a finished goal later gets a new task that isn't done, it moves back to the leftmost column that holds one of its tasks.\n\nWhen an agent completes a goal's last task, Stride also asks it to run the `after_goal` hook and report the result:\n\n- A passing report moves the goal to **Done**\n- A failing report keeps the goal out of **Done** until a passing report arrives or a five-minute grace window ends\n- If no report arrives, Stride moves the goal to **Done** itself when the window ends\n\n[Setting Up Hook Execution](/resources/setting-up-hooks) explains the hooks.",
            image: nil
          },
          %{
            title: "Archiving a Goal",
            content:
              "Hover over the goal's card and click its archive icon. The goal and every task in it that isn't archived yet, finished or not, leave the board straight away, with no confirmation. The bulk bar's **Archive** skips goals.\n\nOn the **Archive** tab each of those tasks still shows the goal it belongs to. Restoring the goal brings back the goal alone, so restore each of its tasks you still need as well. [Archiving Tasks](/resources/archiving-tasks) has the details.",
            image: nil
          },
          %{
            title: "Goals, Targets and Dependencies",
            content:
              "Goals work with two other ways of planning:\n\n- To set the order of the tasks inside a goal, give them dependencies, as [Organizing Tasks with Dependencies](/resources/organizing-with-dependencies) explains\n- To track goals toward a date, add them to a target, as [Planning With Targets](/resources/planning-with-targets) explains\n\nTo share the work in a goal across a team, see [Using Stride With a Team](/resources/using-stride-with-a-team).",
            image: nil
          }
        ]
      }
    ]
  end
end
