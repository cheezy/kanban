defmodule KanbanWeb.ResourcesLive.HowTos.TaskDetails do
  @moduledoc """
  Guides for reading what a task records once an agent has worked on it, and
  for talking about it in comments.

  One of the data modules `KanbanWeb.ResourcesLive.HowToData` concatenates,
  in order, into the Resources catalog. It sits after
  `HowTos.WorkingWithTasks` and before `HowTos.AgentsAndPlanning`.

  Both guides lead with `non-developer`, so they extend that chain after
  reviewing completed work: writing tasks for AI → monitoring task progress →
  reviewing completed work → reading a task's details → commenting and
  mentioning.

  The guides follow `KanbanWeb.TaskLive.ViewComponent` and its components,
  `KanbanWeb.TaskLive.CommentThreadComponent`, `Kanban.Tasks.CommentPolicy`
  and `Kanban.Tasks.CommentNotifier`.
  """

  @doc "The guides in this group, in display order."
  def how_tos do
    [
      %{
        id: "reading-a-tasks-details",
        title: "Reading a Task's Details",
        description:
          "What each section of a finished agent task means, and how to use the test matrix and the diff when you review the work.",
        tags: ["non-developer", "reviewing", "tasks"],
        content_type: "guide",
        reading_time: 7,
        created_at: ~D[2026-10-24],
        steps: [
          %{
            title: "Opening a Task",
            content:
              "Click a task's card on the board to open its details. A goal's card opens the goal's own page instead.\n\nAnyone who can open the board can read a task's details, including someone signed in who is viewing a shared board. **Edit task** in the side panel appears only for the board's owner and members with modify access.\n\nA section appears only when the task has something to show in it. Most sections also need the board's owner to turn them on under **Field visibility**, as [Managing Board Settings](/resources/managing-board-settings) explains. Only **Acceptance Criteria** is on by default.",
            image: nil
          },
          %{
            title: "The Top and the Side Panel",
            content:
              "The top of the details shows the task's ID, its status, priority and complexity, then its title and description.\n\nThe side panel lists **Status**, **Column**, **Author**, **Priority**, **Complexity**, **Estimated files** and **Needs review**, which says **Required** when a person must approve the work and **Auto** when it goes straight to Done. **Created**, **Claimed** and **Completed** show when each happened.",
            image: "/images/resources/guides/reading-a-tasks-details-step-2.png",
            image_width: 985,
            image_height: 656
          },
          %{
            title: "What Was Asked",
            content:
              "These sections hold what the task asked for:\n\n- **Why**, **What** and **Where**: the reason for the work, the change and where it goes. They need the **Context (Why/What/Where)** toggle.\n- **Acceptance criteria**: the definition of done. The list isn't ticked off here; the reviewer's verdict on each criterion is in the Review queue.\n- **Key files**, **Verification steps**, **Pitfalls**, **Security considerations** and **Testing strategy**, each behind its own toggle.\n- **Patterns to follow**, **Database changes** and **Validation rules**, which share the **Technical Notes** toggle.\n- **Out of scope**, **Technology requirements**, **Error handling**, **Integration points** and **Technical details**, each behind its own toggle.\n- **Dependencies**: the tasks this one waits for. It shows whenever there are any, with no toggle. See [Organizing With Dependencies](/resources/organizing-with-dependencies).",
            image: "/images/resources/guides/reading-a-tasks-details-step-3.png",
            image_width: 721,
            image_height: 384
          },
          %{
            title: "The Behaviour/Test Matrix",
            content:
              "**Behaviour/Test Matrix** lists the behaviours the work had to cover, one row each, under seven headings: **Happy path**, **Boundary**, **Error / exception**, **Null / empty**, **Concurrency**, **Lifecycle / wiring** and **Contract / serialization**.\n\nEach row names the test that covers the behaviour, or the reason no test applies, with the kind of test and a status: **Planned**, **Passing**, **Failing** or **Not applicable**.\n\nWhen you review, check that every row is **Passing** or has a reason that makes sense, and look for each named test file under **Changed files**. A row still **Planned** or **Failing** on a finished task is worth a question. The section needs the **Behaviour/Test Matrix** toggle.",
            image: "/images/resources/guides/reading-a-tasks-details-step-4.png",
            image_width: 721,
            image_height: 344
          },
          %{
            title: "Observability",
            content:
              "**Observability** shows what the work should measure and record: **Telemetry**, **Metrics** and **Logging**. It needs the **Observability** toggle, which is off by default.\n\nWhile plans are on, **Telemetry** and **Metrics** are paid fields, so a free board doesn't show them. The values stay on the task, and **Logging** still shows. [Free and Paid Boards](/resources/free-and-paid-boards) explains plans.",
            image: nil
          },
          %{
            title: "What the Agent Reported",
            content:
              "Once a task reaches Review, it shows what the agent reported:\n\n- **Explorer result**: whether the agent sent a helper to read the code before starting (**Dispatched** or **Not dispatched**), how long it took, and what it found or why it was skipped.\n- **Review report**: the agent reviewer's summary and its issues under **Critical**, **Important** and **Minor**, or **No issues**.\n- **Workflow steps**: each step of the agent's workflow, whether it ran, and how long it took.\n\nWhen the task needs review, **Review status** shows whether it was approved, by whom and when, with any notes the reviewer left.",
            image: "/images/resources/guides/reading-a-tasks-details-step-6.png",
            image_width: 721,
            image_height: 776
          },
          %{
            title: "Completion and Actual vs Estimated",
            content:
              "**Completion** shows when the task was finished, who finished it, the agent, its summary and its completion notes. It appears once the task reaches Review, and anyone who can open the board can read it.\n\n**Actual vs estimated** appears once the task is Done. It puts **Actual Complexity**, **Actual Files Changed** and **Time Spent** next to what was estimated, which helps you size the next task. See [Using Complexity and Priority](/resources/using-complexity-priority).",
            image: "/images/resources/guides/reading-a-tasks-details-step-7.png",
            image_width: 721,
            image_height: 540
          },
          %{
            title: "Changed Files and the Diff",
            content:
              "**Changed files** lists every file the agent changed. Click a file to open its diff under it, and click it again to close it.\n\nA long diff stops with **Diff truncated at 500 lines.** and, for a GitHub repository, offers **View full diff in repo**. A file without a diff says **No diff available for this file.**, and an image or other binary file says **Binary file changed — no diff preview.**\n\nRead the diff with the acceptance criteria and the matrix beside it: each criterion should show up in the change, and each test the matrix names should be in the list.",
            image: "/images/resources/guides/reading-a-tasks-details-step-8.png",
            image_width: 721,
            image_height: 342
          },
          %{
            title: "History, Comments and Your Decision",
            content:
              "**History** records when the task was created, moved, reassigned and reprioritized. **Comments** is at the bottom, as [Commenting and Mentioning](/resources/commenting-and-mentioning) explains.\n\nThe details are for reading. To approve the work or ask for changes, use the Review queue, as [Reviewing Completed Work](/resources/reviewing-completed-work) explains.",
            image: nil
          }
        ]
      },
      %{
        id: "commenting-and-mentioning",
        title: "Commenting and Mentioning",
        description:
          "Discuss a task in its comments, mention a teammate so they're notified, and edit or delete what you wrote.",
        tags: ["non-developer", "tasks"],
        content_type: "guide",
        reading_time: 5,
        created_at: ~D[2026-10-24],
        steps: [
          %{
            title: "Where Comments Are",
            content:
              "**Comments** is at the bottom of a task's details and of its edit form. Comments are listed oldest first. When there are none, it says **No comments yet**.\n\nThe list updates for everyone who has the task open. A comment an agent posts shows the agent's name, with the person whose API token it uses.",
            image: nil
          },
          %{
            title: "Who Can Comment",
            content:
              "Every member of the board can comment, including members with read-only access, because a comment discusses a task without changing it.\n\nSomeone viewing a shared board without being a member can read the comments but has no box to write one. A member who is removed from the board can no longer comment or edit their comments.",
            image: nil
          },
          %{
            title: "Writing a Comment",
            content:
              "Type in **Add a comment** and click **Add Comment**. A comment can be up to 10,000 characters.",
            image: nil
          },
          %{
            title: "Mentioning Someone",
            content:
              "Type @ at the start of the comment or after a space. A list of up to 8 board members appears, and it narrows as you type part of a name or email. Use the arrow keys to pick someone and press Enter or Tab to add them, or press Esc to close the list.\n\nOnly a person picked from the list is mentioned; typing @ and a name yourself leaves plain text. You can mention any active member of the board, whatever their access, up to 20 people in one comment. Once posted, a mention shows as a chip with the person's current name.",
            image: "/images/resources/guides/commenting-and-mentioning-step-4.png",
            image_width: 708,
            image_height: 302
          },
          %{
            title: "Who Gets Notified",
            content:
              "Each person you mention gets a notification, except you. Editing a comment notifies only the people the edit adds, so fixing a typo notifies no one. The notification names the task but doesn't copy the comment.\n\nA comment with no mention notifies nobody, even though **Notification preferences** lists a **Comments** row.\n\nMentions arrive in Stride and by email. To change that, open **Notification preferences** and, under **Comments and mentions**, switch **Mentions** off for **In-app** or **Email**.\n\nThe notification opens the task's edit form, which needs modify access. A read-only member lands on the board instead and can open the card from there.",
            image: nil
          },
          %{
            title: "Notifications Need a Paid Board",
            content:
              "When Stride's plans are switched on, a free board sends no notifications. On a paid board, a mentioned person also needs to belong to an Organization to get the email, and only Organization members can change their notification preferences.\n\nComments and mentions themselves work on every board. [Free and Paid Boards](/resources/free-and-paid-boards) explains plans.",
            image: nil
          },
          %{
            title: "Editing and Deleting",
            content:
              "Click **Edit** on your own comment, change it and click **Save**, or **Cancel**. Only the person who wrote a comment can edit it, and an edited comment says so.\n\nClick **Delete** to remove a comment. You can delete your own comments, and the board's owner can delete anyone's; an org-admin counts as the owner of their Organization's boards. Stride asks you to confirm, and a deleted comment can't be brought back. There's no time limit on either.",
            image: "/images/resources/guides/commenting-and-mentioning-step-7.png",
            image_width: 708,
            image_height: 240
          }
        ]
      }
    ]
  end
end
