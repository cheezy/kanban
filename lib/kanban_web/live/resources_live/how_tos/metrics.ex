defmodule KanbanWeb.ResourcesLive.HowTos.Metrics do
  @moduledoc """
  Guides for the board metrics dashboard, each flow metric, the workspace
  Metrics page and the board Compliance page.

  One of the data modules `KanbanWeb.ResourcesLive.HowToData` concatenates,
  in order, into the Resources catalog.
  """

  @doc "The guides in this group, in display order."
  def how_tos do
    [
      %{
        id: "metrics-dashboard",
        title: "Using the Metrics Dashboard",
        description:
          "Get an overview of your board's performance with the metrics dashboard, showing throughput, cycle time, lead time, and wait time at a glance, and, on AI-optimized boards, compliance.",
        tags: ["best-practices", "metrics", "monitoring"],
        content_type: "guide",
        reading_time: 4,
        thumbnail: "/images/resources/metrics-dashboard.png",
        created_at: ~D[2026-02-11],
        steps: [
          %{
            title: "Access the Metrics Dashboard",
            content:
              "Open your board and click its **Metrics** tab. The **Metrics Dashboard** opens with a summary of the board's flow metrics. Every member of the board can open it, including members with view-only access.\n\nThe **Metrics** link in the sidebar is a different page: it opens the workspace Metrics page, which covers all your boards. **Back to Board** takes you back to the board.",
            image: "/images/resources/guides/metrics-button.png",
            image_width: 603,
            image_height: 103
          },
          %{
            title: "Filter Your Data",
            content:
              "The **Filters** card sets what the dashboard counts:\n\n- **Time Range**: **Today**, **Last 7 Days**, **Last 30 Days**, **Last 90 Days** or **All Time**. The range starts at **Last 30 Days**\n- **Agent Filter**: **All Agents**, or one agent to count only the tasks it completed or created (for wait time, only the tasks it completed). **Agent Filter** appears only on AI-optimized boards\n- **Exclude Weekends**: drops Saturdays and Sundays from throughput and takes weekend hours out of each task's time\n\nA change applies as soon as you pick it. The filters apply to the cards and carry over when you click a card.\n\nOn each metric's own page, a range counts back from midnight in your time zone. The dashboard's cards count from midnight UTC, so a card can differ slightly from its page.",
            image: "/images/resources/guides/metrics-filter.png",
            image_width: 1182,
            image_height: 115
          },
          %{
            title: "Understand the Summary Cards",
            content:
              "The dashboard shows a card for each metric:\n\n- **Throughput**: how many tasks were completed in the range. Goals aren't counted\n- **Cycle Time**: how long tasks took once work started, as an average (avg) and a median\n- **Lead Time**: how long tasks took from creation to completion, as an average and a median\n- **Wait Time**: on AI-optimized boards, **Review** and **Backlog** wait; on other boards, **Queue** wait\n- **Compliance**: on AI-optimized boards only, how often agents ran each workflow step. Only the board's owner and members with edit access can open it\n\nTimes show in minutes, hours or days. Click a card to open its detail page.",
            image: "/images/resources/guides/metrics-summary-cards.png",
            image_width: 1182,
            image_height: 120
          },
          %{
            title: "Export Your Data",
            content:
              "The **Throughput**, **Cycle Time**, **Lead Time** and **Wait Time** pages each have an **Export** button. It offers **PDF**, which opens in a new tab, and **Excel**, which downloads an .xlsx file. Both use the filters set on the page.\n\nThe dashboard and the Compliance page have no export. The workspace Metrics page has its own **Export**, described in the Workspace Metrics and Compliance guide.",
            image: nil
          }
        ]
      },
      %{
        id: "throughput-metrics",
        title: "Tracking Throughput",
        description:
          "Measure how many tasks your team completes over time and identify trends in delivery velocity.",
        tags: ["best-practices", "metrics", "monitoring"],
        content_type: "guide",
        reading_time: 3,
        thumbnail: "/images/resources/throughput-metrics.png",
        created_at: ~D[2026-02-11],
        steps: [
          %{
            title: "What Is Throughput?",
            content:
              "Throughput is the number of tasks completed in a time range. A task counts on the day it was completed, and goals aren't counted. It answers the question: \"How much work is getting done?\"\n\nHigher throughput generally indicates a productive team, but quality matters too, so read throughput alongside the other metrics.",
            image: nil
          },
          %{
            title: "Navigate to Throughput",
            content:
              "On the **Metrics Dashboard**, click the **Throughput** card. The filters you set carry over, and **Back to Dashboard** takes you back.\n\nThe page opens with four numbers:\n\n- **Total Tasks**: tasks completed in the range\n- **Avg Per Day**: the total divided by the days that had completions, so quiet days don't lower it\n- **Peak Day** and **Peak Count**: the busiest day and how many tasks were completed on it",
            image: "/images/resources/guides/throughput-summary.png",
            image_width: 1167,
            image_height: 99
          },
          %{
            title: "Reading the Chart",
            content:
              "The **Daily Completions Bar Chart** draws one bar for each day that had completions, with the count beside it. Days with no completions are left out, so look at the dates to spot gaps.\n\nBelow the chart, **Completed Tasks** lists what was finished, day by day, after **Completed Goals** when goals were finished too. On AI-optimized boards, pick an agent in **Agent Filter** to see one agent's throughput.",
            image: "/images/resources/guides/throughput-chart.png",
            image_width: 1167,
            image_height: 390
          },
          %{
            title: "Using Throughput Effectively",
            content:
              "Throughput is most useful when tracked over time:\n\n- Set a baseline by watching throughput over **Last 30 Days**\n- Watch for sustained drops that may indicate process problems\n- Compare throughput before and after process changes\n- Use **Agent Filter** to compare agents and balance work across them",
            image: nil
          }
        ]
      },
      %{
        id: "cycle-time-metrics",
        title: "Understanding Cycle Time",
        description:
          "Measure how long tasks take from the moment work starts until completion, and find opportunities to speed up delivery.",
        tags: ["best-practices", "metrics", "monitoring"],
        content_type: "guide",
        reading_time: 4,
        thumbnail: "/images/resources/cycle-time-metrics.png",
        created_at: ~D[2026-02-11],
        steps: [
          %{
            title: "What Is Cycle Time?",
            content:
              "Cycle time is how long a task takes once work starts. On an AI-optimized board it runs from the moment an agent claims the task until it is completed. On other boards it runs from the task's first move to another column until it is completed. Goals aren't counted.\n\nIt answers the question: \"How long does it take to finish a task once we start working on it?\" Shorter cycle times mean faster delivery and quicker feedback.",
            image: nil
          },
          %{
            title: "Navigate to Cycle Time",
            content:
              "On the **Metrics Dashboard**, click the **Cycle Time** card. The page shows **Average**, **Median**, **Min** and **Max** for the tasks completed in the range.",
            image: "/images/resources/guides/cycle-time-summary.png",
            image_width: 1167,
            image_height: 93
          },
          %{
            title: "Reading the Chart",
            content:
              "**Cycle Time Trend** plots the average cycle time of each day's completed tasks. Once there are two days of data, a dashed trend line shows whether cycle time is rising or falling.\n\nAn average well above the median means a few slow tasks are pulling it up. **Max** shows the slowest, and **Completed Tasks** below the chart lists each task with its time. On AI-optimized boards, **Agent Filter** shows one agent's tasks.",
            image: "/images/resources/guides/cycle-time-chart.png",
            image_width: 1167,
            image_height: 651
          },
          %{
            title: "Reducing Cycle Time",
            content:
              "To improve cycle time:\n\n- Write clearer task descriptions and acceptance criteria\n- Break large tasks into smaller, focused pieces\n- Remove blockers and dependencies where possible\n- Make sure tasks have all the context needed to start immediately\n- Turn on **Exclude Weekends** when nobody works weekends, so a task left on Friday doesn't look slow",
            image: nil
          }
        ]
      },
      %{
        id: "lead-time-metrics",
        title: "Understanding Lead Time",
        description:
          "Measure the total time from when a task is created until it is completed, capturing the full lifecycle from idea to delivery.",
        tags: ["best-practices", "metrics", "monitoring"],
        content_type: "guide",
        reading_time: 4,
        thumbnail: "/images/resources/lead-time-metrics.png",
        created_at: ~D[2026-02-11],
        steps: [
          %{
            title: "What Is Lead Time?",
            content:
              "Lead time is the total time from when a task is created until it is completed. Unlike cycle time, it includes the time a task waits before work begins. Every completed task counts, and goals aren't counted.\n\nLead time answers the question: \"How long does it take from the moment we identify a need until it's delivered?\"",
            image: nil
          },
          %{
            title: "Navigate to Lead Time",
            content:
              "On the **Metrics Dashboard**, click the **Lead Time** card. The page shows **Average**, **Median**, **Min** and **Max** for the tasks completed in the range.",
            image: "/images/resources/guides/lead-time-summary.png",
            image_width: 1167,
            image_height: 93
          },
          %{
            title: "Lead Time vs. Cycle Time",
            content:
              "On an AI-optimized board the two fit together like this:\n\n- Lead time = backlog wait + cycle time\n- Backlog wait runs from creation until an agent claims the task\n- Cycle time runs from the claim until the task is completed\n\nReview wait starts when the agent completes the task, so it is in neither. **Lead Time Trend** plots the average lead time for each day. A large gap between lead time and cycle time means tasks spend a long time waiting to be picked up.",
            image: "/images/resources/guides/lead-time-chart.png",
            image_width: 1167,
            image_height: 651
          },
          %{
            title: "Reducing Lead Time",
            content:
              "To improve lead time:\n\n- Prioritize your backlog regularly so important tasks don't sit waiting\n- Keep the **Ready** column small: only add tasks that can start soon\n- Write tasks agents can claim straight away, with the context they need\n- Watch the gap between lead time and cycle time to see where delays occur",
            image: nil
          }
        ]
      },
      %{
        id: "wait-time-metrics",
        title: "Understanding Wait Time",
        description:
          "Identify where tasks are sitting idle with wait time metrics, covering both backlog wait and review wait.",
        tags: ["best-practices", "metrics", "monitoring"],
        content_type: "guide",
        reading_time: 4,
        thumbnail: "/images/resources/wait-time-metrics.png",
        created_at: ~D[2026-02-11],
        steps: [
          %{
            title: "What Is Wait Time?",
            content:
              "Wait time is how long tasks spend waiting rather than being worked on. On an AI-optimized board Stride tracks two kinds:\n\n- **Backlog Wait Time**: from when a task is created until an agent claims it\n- **Review Wait Time**: from when the agent completes a task until a reviewer approves it or requests changes\n\nOther boards have one kind, **Queue Wait Time**: from creation until the task's first move to another column. Wait time shows where work gets stuck.",
            image: nil
          },
          %{
            title: "Navigate to Wait Time",
            content:
              "On the **Metrics Dashboard**, the **Wait Time** card shows **Review** and **Backlog** wait, or **Queue** wait on other boards. Click it to open the detail page.",
            image: "/images/resources/guides/wait-time-metrics-step-2.png",
            image_width: 238,
            image_height: 120
          },
          %{
            title: "Reading the Two Sections",
            content:
              "The page has a section for each kind of wait. Each one shows **Average**, **Median**, **Min** and **Max**, and a list of the tasks behind them: **Review Wait Tasks** and **Backlog Wait Tasks**.\n\n- A high backlog wait means tasks are created but not picked up: you may need more agents or a better-ordered backlog\n- A high review wait means finished work is waiting for people: reviewers may be a bottleneck\n\nThere is no trend chart; change **Time Range** to compare periods. On this page **Agent Filter** matches the agent who completed the task.",
            images: [
              %{
                url: "/images/resources/guides/review-wait-time.png",
                alt: "Review Wait Time",
                width: 1167,
                height: 533
              },
              %{
                url: "/images/resources/guides/backlog-wait-time.png",
                alt: "Backlog Wait Time",
                width: 1167,
                height: 533
              }
            ]
          },
          %{
            title: "Reducing Wait Time",
            content:
              "To reduce backlog wait:\n\n- Keep the backlog prioritized so agents always have clear next tasks\n- Make sure tasks have complete descriptions so agents can start immediately\n- Match task capabilities to available agents\n\nTo reduce review wait:\n\n- Set aside regular time for reviewing completed work\n- Consider setting `needs_review: false` for low-risk tasks\n- Open the **Review queue** regularly to see every task waiting for you",
            image: nil
          }
        ]
      },
      %{
        id: "workspace-and-compliance-metrics",
        title: "Workspace Metrics and Compliance",
        description:
          "See flow metrics across all your boards on the workspace Metrics page, and check how agents follow the workflow on a board's Compliance page.",
        tags: ["metrics", "best-practices", "monitoring"],
        content_type: "guide",
        reading_time: 6,
        thumbnail: "/images/resources/workspace-and-compliance-metrics.png",
        created_at: ~D[2026-10-23],
        steps: [
          %{
            title: "Two More Views of Your Metrics",
            content:
              "Besides each board's **Metrics Dashboard**, Stride has two more metrics pages:\n\n- The **Metrics** link in the sidebar opens the workspace Metrics page, which covers every board you can open\n- On an AI-optimized board, the dashboard's **Compliance** card opens the board's Compliance page, which shows how agents follow the workflow",
            image: nil
          },
          %{
            title: "Open the Workspace Metrics Page",
            content:
              "Click **Metrics** in the sidebar. The toolbar at the top has:\n\n- A time range menu: the last 7, 14, 30 or 90 days. It starts at 14 days\n- **All boards**: a list of your boards, all ticked at first. Untick a board to leave it out\n- **Exclude Weekends**\n- **Export**\n\nA reload puts every control back to 14 days, all boards and weekends included.",
            image: "/images/resources/guides/workspace-and-compliance-metrics-step-2.png",
            image_width: 1167,
            image_height: 167
          },
          %{
            title: "Read the KPI Strip",
            content:
              "Under the toolbar, four cells sum up the period:\n\n- **Cycle time · median**\n- **Lead time · median**\n- **Throughput**, in tasks per day\n- **Wait time · Review**\n\nThe three time cells are medians, not averages; **Throughput** is the average number of tasks completed per day. Each cell shows the change against the previous period of the same length, in green when it went the good way: down for times, up for throughput.",
            image: nil
          },
          %{
            title: "Read the Daily Charts and Agents",
            content:
              "Three charts show the period day by day: **Cycle time · daily median (min)**, **Lead time · daily median (min)** and **Throughput · tasks completed per day**.\n\nBeside the throughput chart, the agents panel ranks the top six contributors **by completed**, agents before people. Each row shows how many tasks they completed and their success rate: the share of their tasks that were approved or needed no review.",
            image: "/images/resources/guides/workspace-and-compliance-metrics-step-4.png",
            image_width: 1182,
            image_height: 234
          },
          %{
            title: "Read the Cumulative Flow",
            content:
              "**Cumulative flow** shows how much work sat in each column over time, in bands for **Backlog**, **Ready**, **Doing**, **Review** and **Done**. Stride rebuilds it from task timestamps, which can't tell a task in Ready from one in Backlog, so the Ready band stays empty.\n\n**Show Done** starts ticked. Untick it to drop the Done band, so the other four bands fill the chart. It changes only this chart.",
            image: nil
          },
          %{
            title: "Export the Workspace Report",
            content:
              "Click **Export** and choose **PDF** or **Excel**. The report uses the period, boards and weekend setting you picked, and your time zone. The file is named like `stride_workspace_metrics_14d_2026-10-23.pdf`.",
            image: nil
          },
          %{
            title: "Open a Board's Compliance Page",
            content:
              "On an AI-optimized board, click the **Compliance** card on the **Metrics Dashboard**. Only the board's owner and members with edit access can open it; anyone else is sent back to the board with a message.\n\nThe page has no filters and no export, and it covers every task on the board, for all time. Its numbers come from the `workflow_steps` agents send when they complete a task: which of the six steps they ran, and why they skipped any.",
            image: nil
          },
          %{
            title: "Read Step Dispatch Rates",
            content:
              "**Step Dispatch Rates** has a row for each workflow step, with the columns **Step**, **Dispatch Rate**, **Dispatched** and **Total**. The hook steps show as After Doing and Before Review; the others show as agents record them: `explorer`, `planner`, `implementation` and `reviewer`.\n\nThe bar takes the Done column's colour at 80% or more, the Review column's colour from 50%, and red below 50%. A low rate isn't always a problem: many skips are deliberate, and **Skip Reasons** says why.",
            image: "/images/resources/guides/workspace-and-compliance-metrics-step-8.png",
            image_width: 1167,
            image_height: 374
          },
          %{
            title: "Read Skip Reasons and Agent Compliance",
            content:
              "**Skip Reasons** counts why steps were skipped, most common first. The reasons are **Decision matrix skip**, **Ran inline, not dispatched**, **Hook body empty**, **Settled by task spec**, **Folded into prior step** and **Matrix deviation**. A skip reported without a code shows its reason word for word.\n\n**Matrix deviation** is the reason to look into: it means the decision matrix called for a step and the agent chose not to run it. Every other reason records a skip the workflow allows.\n\n**Compliance by Agent** has a row for each agent, with **Agent**, **Total Tasks**, **Tasks With Steps** and **Avg Steps / Task**. An agent with fewer tasks with steps than tasks isn't reporting its workflow.",
            image: "/images/resources/guides/workspace-and-compliance-metrics-step-9.png",
            image_width: 1182,
            image_height: 562
          }
        ]
      }
    ]
  end
end
