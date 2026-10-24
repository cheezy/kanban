defmodule KanbanWeb.ResourcesLive.HowTos.AgentsAndPlanning do
  @moduledoc """
  Guides for keeping track of work across boards: the Agents page, My Work,
  and planning with delivery targets and goal pages.

  One of the data modules `KanbanWeb.ResourcesLive.HowToData` concatenates,
  in order, into the Resources catalog. It sits after
  `HowTos.TaskDetails` and before `HowTos.NotificationsAndIntegrations`.

  - `watching-your-agents` leads with `ai-agents`, so it ends that chain:
    writing tasks for AI → watching your agents.
  - The other two lead with `planning`, a tag only they carry, so they form
    a pair: your work across boards → planning with targets.

  The guides follow `AgentsLive` and its components, `MyWorkLive`, the
  `TargetLive` LiveViews and `GoalLive.Show`. `Kanban.Tasks.Interventions`,
  `Kanban.Tasks.MyWork` and `Kanban.Targets` are the rules behind them.
  """

  @doc "The guides in this group, in display order."
  def how_tos do
    [
      %{
        id: "watching-your-agents",
        title: "Watching Your Agents",
        description:
          "See what every agent is doing across your boards, spot stuck work and at-risk targets, and step in with Reassign or Reprioritize.",
        tags: ["ai-agents", "monitoring"],
        content_type: "guide",
        reading_time: 6,
        created_at: ~D[2026-10-24],
        steps: [
          %{
            title: "Opening the Agents Page",
            content:
              "Click **Agents** in the sidebar. Everyone signed in has it, on every plan.\n\nThe page covers tasks on the boards you belong to, whatever your access, plus the boards an org-admin manages. A shared board you never joined isn't included, and goals aren't counted as agent work.\n\nAn agent here is the name an AI agent puts on the tasks it creates or completes, together with the person running it. The same agent run by two people shows up twice.",
            image: nil
          },
          %{
            title: "The Header",
            content:
              "**Agent activity** sums up your agents. Narrow it with the two menus at the top: one board or **All boards**, and **Today**, **Last 7 days**, **Last 30 days**, **Last 90 days** or **All time**, which is where it starts.\n\n- **Working**: agents holding a task in Doing.\n- **Waiting**: agents with a task in Review and none in Doing.\n- **Idle**: everyone else.\n- **Stuck**: agents with a Doing or Review task that hasn't moved for over an hour.\n\nThe tiles on the right count what was created, claimed, completed and approved today. **Delivery trends**, further down, charts completions day by day.",
            image: "/images/resources/guides/watching-your-agents-step-2.png",
            image_width: 1194,
            image_height: 173
          },
          %{
            title: "Delivery Health",
            content:
              "**Delivery health** counts the delivery targets you can see by status: **On-track**, **At-risk**, **Missed** and **Complete**. With none, it says **No delivery targets yet.** [Planning With Targets](/resources/planning-with-targets) explains targets and how their status is worked out.",
            image: "/images/resources/guides/watching-your-agents-step-3.png",
            image_width: 666,
            image_height: 114
          },
          %{
            title: "The Roster and the Feed",
            content:
              "On the left, a card for each agent shows whether it is **Working**, **Waiting for review** or **Idle**, with its tasks **Today**, its **Success** rate and its **Claims**. The most recently active agents come first, and agents working on a goal of an at-risk target move to the top. An agent with no activity for 14 days folds into a Dormant group at the bottom.\n\nOn the right, the feed lists the latest 200 events, grouped under **Today**, **Yesterday** and earlier dates. Use **All**, **Claims**, **Reviewed** and **Completions** to filter it. Newly created tasks appear only under **All**. The page updates by itself as agents work.",
            image: "/images/resources/guides/watching-your-agents-step-4.png",
            image_width: 1194,
            image_height: 426
          },
          %{
            title: "Looking at One Agent",
            content:
              "Click an agent's card to filter the feed to that agent and open its details:\n\n- **Current work**: the task it holds now.\n- **Claims**: the tasks it has claimed.\n- **Failures**: its tasks whose review was rejected.\n- **Recent activity**: its last 20 events.\n\nClick the card again, or **Clear**, to see every agent. The details are for reading only.",
            image: "/images/resources/guides/watching-your-agents-step-5.png",
            image_width: 1184,
            image_height: 518
          },
          %{
            title: "Why Targets Are at Risk",
            content:
              "A target turns **At-risk** when its work falls behind or its estimate slips, as [Planning With Targets](/resources/planning-with-targets) explains. When an at-risk target has a stalled goal or an estimate after its date, **Why targets are at risk** appears on the page and gives the reason. It lists each stalled goal with the agents holding it up, and says when the estimate is after the target date. A goal has stalled when an agent working on it is **Stuck** or **Dormant**.",
            image: nil
          },
          %{
            title: "Who Can Step In",
            content:
              "Next to a stalled goal, **Reassign** and **Reprioritize** let you get it moving again. They appear only for:\n\n- the target's owner, if they also belong to the goal's board, with any access, or\n- the board's owner. An org-admin counts as the owner of their Organization's boards.\n\nOther members don't see them, and Stride checks again when you confirm. No paid plan is needed.",
            image: nil
          },
          %{
            title: "Reassigning or Reprioritizing a Goal",
            content:
              "The dialog lists the goal and the tasks under it that haven't started yet and that no one has claimed. Tasks in Doing, Review or Done are never changed.\n\n- **Reassign**: pick someone in **New owner**. Only the board's owner, members with modify access and org-admins are offered.\n- **Reprioritize**: pick a **New priority**: **Low**, **Medium**, **High** or **Critical**.\n\nClick **Reassign** or **Reprioritize** to apply it, or **Cancel**. A task that has moved on by the time you confirm is left alone, and the message names any task it skipped as already claimed.\n\nThe new owner gets one notification, for the goal, unless the goal was already theirs or you picked yourself. Reprioritizing sends none. While plans are on, notifications only come from paid boards, as [Free and Paid Boards](/resources/free-and-paid-boards) explains. Each changed task records the change in its history.\n\nThis is narrower than changing the goal's owner on its edit form, which moves all of its unfinished tasks. [Using Stride With a Team](/resources/using-stride-with-a-team) covers that.",
            image: nil
          },
          %{
            title: "Undo",
            content:
              "After a change, a message at the bottom of the page says **Goal reassigned.** or **Goal reprioritized.** and offers **Undo** for 8 seconds. Undo puts each task back the way it was, except a task that has been claimed or has moved on since.\n\nYou can't undo a change once the 8 seconds are up, after you make another change, or after you reload or leave the page. If you've lost the right to step in, Stride says **You are no longer allowed to undo this change.**",
            image: nil
          }
        ]
      },
      %{
        id: "your-work-across-boards",
        title: "Your Work Across Boards",
        description:
          "See every open task assigned to you, across all your boards, in one list with the most urgent first.",
        tags: ["planning", "workflow"],
        content_type: "guide",
        reading_time: 3,
        created_at: ~D[2026-10-24],
        steps: [
          %{
            title: "Opening My Work",
            content:
              "Click **My Work** in the sidebar. Everyone signed in has it, on every plan.",
            image: nil
          },
          %{
            title: "What's Listed",
            content:
              "My Work lists the tasks assigned to you that aren't completed or archived, including goals, defects and blocked tasks. Anything in a Done column is left out.\n\nOnly boards you belong to count, including the boards you manage as an org-admin. A shared board you never joined, or a board you've been removed from, doesn't appear.",
            image: "/images/resources/guides/your-work-across-boards-step-2.png",
            image_width: 1198,
            image_height: 306
          },
          %{
            title: "How It's Ordered",
            content:
              "Tasks are grouped into one card per board, with the boards in alphabetical order. Inside a board they run **Critical**, **High**, **Medium**, **Low**, then by ID. Each row shows the task's ID, title, up to three labels, priority and board.\n\nTasks have no due dates of their own. Dates come from delivery targets, as [Planning With Targets](/resources/planning-with-targets) explains.",
            image: nil
          },
          %{
            title: "Opening a Task",
            content:
              "- Click the board's name to open the board.\n- Click a goal to open its goal page.\n- Click a task to open it for editing.\n- On a board where you're read-only, a task opens the board searched for that task's ID instead.",
            image: nil
          },
          %{
            title: "Keeping It Current",
            content:
              "The list is loaded when you open the page and doesn't update by itself, so reload it to see new work. When nothing is assigned to you, it says **Nothing assigned to you**. To learn how work gets assigned, see [Using Stride With a Team](/resources/using-stride-with-a-team).",
            image: nil
          }
        ]
      },
      %{
        id: "planning-with-targets",
        title: "Planning With Targets",
        description:
          "Group goals from any of your boards under a dated target, follow its progress and status, and archive it when it's done.",
        tags: ["planning", "workflow"],
        content_type: "guide",
        reading_time: 6,
        created_at: ~D[2026-10-24],
        steps: [
          %{
            title: "What a Target Is",
            content:
              "A delivery target groups goals toward a date. Its goals can come from several boards, and the target doesn't belong to any one board.\n\nTargets live on the **Boards** page. **New Target** and **Archived targets** are in the header, and the **Targets** strip shows the targets you can see, with their date, estimate, status and progress. You see a target through its goals on the boards you belong to.",
            image: "/images/resources/guides/planning-with-targets-step-1.png",
            image_width: 1179,
            image_height: 160
          },
          %{
            title: "Creating a Target",
            content:
              "Click **New Target**. **Name** and **Target Date** are required, and **Description** is optional. Anyone signed in can create a target, and **Owner** shows that it's yours.\n\nClick **Create Target**. Stride opens the target's edit page so you can add goals.",
            image: "/images/resources/guides/planning-with-targets-step-2.png",
            image_width: 666,
            image_height: 485
          },
          %{
            title: "Adding Goals",
            content:
              "The edit page lists **Assigned Goals** and **Available Goals**. Click **Assign** to add a goal, or **Unassign** to take it off.\n\nAvailable goals are goals on boards you can open that aren't in a target yet. A goal belongs to one target at a time, so the other target's owner has to unassign it first. **Hide archived goals** starts ticked.\n\nTo assign a goal you need owner or modify access on its board, otherwise Stride says **Could not assign goal**. Who works on a goal is set on the goal itself, as [Using Stride With a Team](/resources/using-stride-with-a-team) explains.",
            image: "/images/resources/guides/planning-with-targets-step-3.png",
            image_width: 872,
            image_height: 253
          },
          %{
            title: "Editing a Target",
            content:
              "Click **Edit target** on the target's page, change its details, and click **Save Target**, which takes you back to the Boards page. Only the target's owner can edit it. Anyone else sees **Only the target owner can edit this target**.",
            image: nil
          },
          %{
            title: "The Target Page",
            content:
              "Click a target in the strip to open its page. It shows the date and status, the estimated completion date, and a bar of the goals' tasks by **Backlog**, **Ready**, **Doing**, **Review** and **Done**. Under **Goals**, each goal shows its own progress, and clicking it opens the goal page.\n\nOnly the owner can open a target's page. Anyone else who clicks it sees **Target not found**, even though the target is in their strip.",
            image: "/images/resources/guides/planning-with-targets-step-5.png",
            image_width: 1194,
            image_height: 328
          },
          %{
            title: "Progress and Status",
            content:
              "Progress counts the tasks under the target's goals. An archived task counts only if it was completed.\n\n- **Complete**: every goal is done.\n- **Missed**: the date has passed.\n- **At-risk**: the share of work done trails the share of time gone by more than 15 points, or the estimated completion is after the date. The estimate comes from how long tasks have been taking on those boards.\n- **On-track**: anything else, including a target with no goals.\n\nThe Agents page shows the same statuses, as [Watching Your Agents](/resources/watching-your-agents) explains.",
            image: nil
          },
          %{
            title: "Archiving a Finished Target",
            content:
              "Once a target is **Complete**, its owner sees **Archive target** on its page. Confirm, and the target leaves the strip and the Agents page. Only a complete target can be archived, so a target with no goals never can.",
            image: nil
          },
          %{
            title: "Archived Targets",
            content:
              "**Archived targets** in the Boards header lists them. Click **Unarchive** to bring one back. The owner can do this at any time. The list also shows colleagues' archived targets with goals on your boards, but only a target's owner can unarchive it. Anyone else gets **Target not found**. When there are none, the page says **No archived targets.**",
            image: nil
          },
          %{
            title: "The Goal Page",
            content:
              "Open a goal from its card on a board, from the target page, or from My Work. Members of the board can open it.\n\n- The header shows the goal's progress by column, and **Working on it** shows the people and agents involved.\n- **Hierarchy** lists the goal's tasks by column. Clicking one opens it for editing, which needs owner or modify access. A read-only member is sent back to the board with a message saying they don't have permission.\n- **Progress** and **Time** on the right sum up how it's going.\n- **History** records changes to the goal itself, such as **Assigned to**, **Reassigned** and **Priority changed**.\n\n**Back to Board** returns to the board.",
            image: "/images/resources/guides/planning-with-targets-step-9.png",
            image_width: 1219,
            image_height: 666
          }
        ]
      }
    ]
  end
end
