defmodule KanbanWeb.ResourcesLive.HowTos.Boards do
  @moduledoc """
  Guides for running a board day to day: its settings and labels, search and
  filters, bulk actions, and the archive.

  One of the data modules `KanbanWeb.ResourcesLive.HowToData` concatenates,
  in order, into the Resources catalog. It sits right after
  `HowTos.GettingStarted`, and every guide leads with the `boards` tag, so
  navigation runs from creating your first board → board settings → search
  and filters → bulk actions → the archive → free and paid boards.

  The guides follow the board LiveViews and components:
  `BoardLive.SettingsFormComponent`, `BoardLive.LabelsManagerComponent`,
  `BoardFilterBar`, `KeyboardShortcutsHelp`, `BulkActionBar` and
  `ArchiveLive.Index`.
  """

  @doc "The guides in this group, in display order."
  def how_tos do
    [
      %{
        id: "managing-board-settings",
        title: "Managing Board Settings",
        description:
          "Rename a board, share it read-only with every signed-in user, choose which task fields show, and manage labels.",
        tags: ["boards", "tasks"],
        content_type: "guide",
        reading_time: 4,
        created_at: ~D[2026-10-24],
        steps: [
          %{
            title: "Opening Settings",
            content:
              "Click the **Settings** tab at the top of a board to open **Board settings**. Every member of the board sees the tab. People viewing a shared board without being a member don't.",
            image: nil
          },
          %{
            title: "Name and Description",
            content:
              "Change the board's **Name** and **Description**, then click **Save**, or **Cancel** to leave them as they were.\n\nOnly the board's owner can change these. On a board in an Organization's workspace, its org-admins can too. Everyone else sees a note saying only the owner can change them, in place of the form.",
            image: "/images/resources/guides/managing-board-settings-step-2.png",
            image_width: 594,
            image_height: 333
          },
          %{
            title: "Sharing a Board Read-Only",
            content:
              "Tick **Make board publicly readable** and click **Save** to let anyone signed in to Stride open the board from its link. They can read every task, including completion notes, and open the archive and metrics, but they can't change anything. A banner at the top of the board tells them it is shared publicly and read-only.\n\nPeople who aren't signed in still can't see the board, and it doesn't appear in anyone else's list of boards. Members keep the access they already had. To make the board private again, untick the box and click **Save**.",
            image: nil
          },
          %{
            title: "Field Visibility",
            content:
              "**Field visibility** chooses which task fields the board's screens show. Each toggle saves as soon as you click it, with no Save button. A new board shows only **Acceptance Criteria**. Turn on others, such as **Key Files**, **Verification Steps**, **Pitfalls** or **Testing Strategy**, when your team uses them.\n\nHiding a field only changes what the board shows. The data stays on the task, and agents can still fill hidden fields in through the API. Only the board's owner can change field visibility.",
            image: "/images/resources/guides/managing-board-settings-step-4.png",
            image_width: 594,
            image_height: 352
          },
          %{
            title: "Labels",
            content:
              "**Labels** tag tasks so you can find them later. To add one, type a name in **Label name**, pick one of nine colours, and click **Add label**. A name can be up to 40 characters, and no two labels on a board can share a name, ignoring capitals. Changes save immediately.\n\n- **Edit** renames or recolours a label. Click **Save** when you're done.\n- **Delete** removes the label from every task that has it. The tasks themselves stay.\n\nThe board's owner, its org-admins and members with modify access can manage labels. Read-only members see the list. To put a label on a task, tick it in the **Labels** section of the task form, or add it to many cards at once as [Editing Many Cards at Once](/resources/bulk-editing-cards) explains.",
            image: "/images/resources/guides/managing-board-settings-step-5.png",
            image_width: 593,
            image_height: 354
          },
          %{
            title: "Who Can Change What",
            content:
              "- **Name**, **Description**, sharing and **Field visibility**: the owner, and an Organization's org-admins on its boards.\n- **Labels**: the owner, org-admins, and members with modify access.\n- Every member can open **Settings** to see the labels.\n\nTo change someone's access, see [Inviting Team Members](/resources/inviting-team-members).",
            image: nil
          }
        ]
      },
      %{
        id: "finding-work-with-search-and-filters",
        title: "Finding Work With Search and Filters",
        description:
          "Search a board by title or ID, filter it by type, priority, assignee or label, share the filtered view, and use the keyboard shortcuts.",
        tags: ["boards", "monitoring"],
        content_type: "guide",
        reading_time: 4,
        created_at: ~D[2026-10-24],
        steps: [
          %{
            title: "The Filter Bar",
            content:
              "The bar above a board's columns searches and filters its cards. Everyone who can open the board can use it, including read-only members and people viewing a shared board. For a quick tour of the board as a whole, see [Monitoring Task Progress](/resources/monitoring-task-progress).",
            image: nil
          },
          %{
            title: "Searching",
            content:
              "Type in **Search title or ID** to narrow the board as you type. It matches part of a task's title or its ID, such as W12, ignoring capitals. It doesn't search descriptions. A search can be up to 100 characters.\n\nEach column then shows how many of its cards match, out of how many it holds, and columns with no matches say so.",
            image: "/images/resources/guides/finding-work-with-search-and-filters-step-2.png",
            image_width: 1103,
            image_height: 285
          },
          %{
            title: "Filtering",
            content:
              "Use the menus beside the search box:\n\n- **All types**: **Work**, **Defect** or **Goal**.\n- **All priorities**: **Low**, **Medium**, **High** or **Critical**.\n- **All assignees**: a member, or **Unassigned**.\n- **All labels**: one of the board's labels. This menu only appears once the board has labels.\n\nSearch and filters combine, so a card must match all of them. A goal stays on the board while one of its tasks matches, so you can see what the task belongs to.",
            image: nil
          },
          %{
            title: "Sharing a Filtered View",
            content:
              "The search and filters are kept in the page's address. Reloading the page or going back keeps them, and sending the link to a teammate shows them the same filtered board. **Clear filters** shows every card again.",
            image: nil
          },
          %{
            title: "Reordering While Filtered",
            content:
              "Dragging cards to reorder them is off while a search or filter is active, because the board can't place a card between cards it's hiding. People who can move cards see **Drag reordering is off while filters are active.** under the bar. Clear the filters to drag again.",
            image: nil
          },
          %{
            title: "Keyboard Shortcuts",
            content:
              "- `/` puts the cursor in the search box.\n- `?` shows or hides the **Keyboard shortcuts** list.\n- **Esc** closes that list, or clears the cards you've selected for a bulk action.\n\nThe shortcuts don't fire while you're typing in a field.",
            image: "/images/resources/guides/finding-work-with-search-and-filters-step-6.png",
            image_width: 434,
            image_height: 174
          }
        ]
      },
      %{
        id: "bulk-editing-cards",
        title: "Editing Many Cards at Once",
        description:
          "Select several cards on a board, then move, assign, label or archive them in one step.",
        tags: ["boards", "tasks", "workflow"],
        content_type: "guide",
        reading_time: 4,
        created_at: ~D[2026-10-24],
        steps: [
          %{
            title: "Who Can Use Bulk Actions",
            content:
              "The board's owner and members with modify access see **Select** at the top of the board. Read-only members and people viewing a shared board don't.\n\nWhen plans are on, bulk actions need a paid board, one in an Organization's workspace. A free board shows a **Bulk actions** lock with **Available to organizations** instead. See [Free and Paid Boards](/resources/free-and-paid-boards).",
            image: nil
          },
          %{
            title: "Selecting Cards",
            content:
              "Click **Select** to show a checkbox on every card and the bulk bar above the columns, then tick the cards you want. Clicking a card ticks it too.\n\n**Select all** at the top of a column ticks every card that column is showing, so a search or filter narrows it. **Clear all** unticks them. **Esc** unticks every card but leaves you selecting. Click **Done selecting** when you're finished.",
            image: "/images/resources/guides/bulk-editing-cards-step-2.png",
            image_width: 1097,
            image_height: 382
          },
          %{
            title: "Moving Cards",
            content:
              "The bulk bar's buttons work once at least one card is ticked. Choose a column in **Move to…** and click **Move**. The cards go to the bottom of that column.\n\nGoals are skipped, because a goal moves with its tasks. If the move would take the column past its WIP limit, nothing moves.",
            image: "/images/resources/guides/bulk-editing-cards-step-3.png",
            image_width: 1126,
            image_height: 51
          },
          %{
            title: "Assigning Cards",
            content:
              "Choose a person in **Assign to…** and click **Assign**, or choose **Unassigned** to clear the assignee. Only people who can work on the board are offered, and each new assignee gets a notification. Goals are skipped.",
            image: nil
          },
          %{
            title: "Adding and Removing Labels",
            content:
              "Choose a label in **Add label…** and click **Add**, or choose one in **Remove label…** and click **Remove**. These only appear once the board has labels, and they apply to goals as well.",
            image: nil
          },
          %{
            title: "Archiving Cards",
            content:
              "**Archive** takes the selected cards off the board after you confirm. Goals are skipped. You can bring them back later, as [Archiving Tasks](/resources/archiving-tasks) explains. **Clear selection** unticks every card without changing anything.",
            image: nil
          },
          %{
            title: "All or Nothing",
            content:
              "Each bulk action changes every selected card or none of them. If something gets in the way, like a full column or a card someone else just archived, the board shows a message and nothing changes.",
            image: nil
          }
        ]
      },
      %{
        id: "archiving-tasks",
        title: "Archiving Tasks",
        description:
          "Take finished work off a board, find it again in the archive, restore or delete it, and export it as CSV.",
        tags: ["boards", "tasks"],
        content_type: "guide",
        reading_time: 4,
        created_at: ~D[2026-10-24],
        steps: [
          %{
            title: "Archiving a Card",
            content:
              "Hover over a card and click its archive icon to take it off the board straight away, with no confirmation. Archiving a goal archives its tasks too. The board's owner and members with modify access can archive. To archive several cards at once, see [Editing Many Cards at Once](/resources/bulk-editing-cards).",
            image: nil
          },
          %{
            title: "The Archive Page",
            content:
              "The **Archive** tab lists the board's archived tasks. Anyone who can open the board can open it.\n\n- **Total archived** and **Completed** count them.\n- Tasks are grouped under their goal, and the rest are under **Tasks Without Goals**. **Collapse all** and **Expand all** fold the groups.\n- **Back to Board** returns to the board.",
            image: "/images/resources/guides/archiving-tasks-step-2.png",
            image_width: 1198,
            image_height: 434
          },
          %{
            title: "Searching and Filtering",
            content:
              "Type in **Search archived tasks…** to search by title. The chips below narrow the list:\n\n- **All** or **Completed**.\n- **Assignee**: one person, or **Unassigned**.\n- **Date range**: set **From** and **To**, then click **Apply**, or **Clear**. It uses the day each task was archived.",
            image: nil
          },
          %{
            title: "Restoring or Deleting a Task",
            content:
              "Open a row's actions menu:\n\n- **Restore** puts the task back on the board, at the bottom of the column it came from. If its assignee can no longer work on the board, the task comes back unassigned.\n- **Delete forever** removes the task for good, after you confirm. It can't be undone.\n\nThe board's owner and members with modify access see both. Everyone else sees **Read-only access**.",
            image: "/images/resources/guides/archiving-tasks-step-4.png",
            image_width: 1162,
            image_height: 152
          },
          %{
            title: "Archiving Old Tasks",
            content:
              "**Archive old (30d+)** archives every completed task on the board that was completed more than 30 days ago, whichever column it's in, after you confirm. The board's owner and members with modify access see it. To undo it, restore the tasks one at a time.",
            image: nil
          },
          %{
            title: "Exporting the Archive",
            content:
              "**Export CSV** downloads every archived task on the board as a spreadsheet, whatever the page is filtered to. It has one row per task, with its ID, title, type, goal, assignee, archive reason, when it was archived and who archived it. Anyone who can open the board can export it.",
            image: nil
          }
        ]
      }
    ]
  end
end
