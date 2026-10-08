defmodule KanbanWeb.ResourcesLive.HowTos.Metrics do
  @moduledoc """
  Guides for the metrics dashboard and each flow metric.

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
          "Get an overview of your board's performance with the metrics dashboard, showing throughput, cycle time, lead time, and wait time at a glance.",
        tags: ["best-practices", "metrics", "monitoring"],
        content_type: "guide",
        reading_time: 3,
        thumbnail: "/images/resources/metrics-dashboard.png",
        created_at: ~D[2026-02-11],
        steps: [
          %{
            title: "Access the Metrics Dashboard",
            content:
              "From your board view, click **Metrics** in the navigation to open the metrics dashboard. This page provides a high-level summary of all four key metrics for your board.",
            image: "/images/resources/guides/metrics-button.png",
            image_width: 539,
            image_height: 53
          },
          %{
            title: "Filter Your Data",
            content:
              "Use the filters at the top of the dashboard to narrow your view:\n\n- **Time Range**: Today, Last 7 Days, Last 30 Days, Last 90 Days, or All Time\n- **Agent**: Filter by a specific agent to see their individual performance\n- **Exclude Weekends**: Toggle to remove weekend data from calculations\n\nFilters apply to all metrics shown on the dashboard.",
            image: "/images/resources/guides/metrics-filter.png"
          },
          %{
            title: "Understand the Summary Cards",
            content:
              "The dashboard displays summary cards for each metric:\n\n- **Throughput**: How many tasks are being completed over time\n- **Cycle Time**: How long tasks take from start to finish\n- **Lead Time**: Total time from task creation to completion\n- **Wait Time**: How long tasks sit idle before work begins or review happens\n\nClick on any card to navigate to the detailed view for that metric.",
            image: "/images/resources/guides/metrics-summary-cards.png"
          },
          %{
            title: "Export Your Data",
            content:
              "Each metric supports exporting to **PDF** or **Excel** format. Use the export dropdown on any metric's detail page to download reports for sharing with your team.",
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
              "Throughput measures the **number of tasks completed** within a given time period. It answers the question: \"How much work is getting done?\"\n\nHigher throughput generally indicates a productive team, but quality matters too — throughput should be considered alongside other metrics.",
            image: nil
          },
          %{
            title: "Navigate to Throughput",
            content:
              "From the metrics dashboard, click **Throughput** to see the detailed view. You can also navigate directly from the board by going to **Metrics → Throughput**.",
            image: "/images/resources/guides/throughput-summary.png"
          },
          %{
            title: "Reading the Chart",
            content:
              "The throughput chart shows completed tasks over your selected time range. Look for:\n\n- **Upward trends**: Team is delivering more over time\n- **Flat lines**: Consistent delivery rate\n- **Dips**: Potential blockers, holidays, or capacity changes\n\nUse the agent filter to compare individual agent throughput.",
            image: "/images/resources/guides/throughput-chart.png"
          },
          %{
            title: "Using Throughput Effectively",
            content:
              "Throughput is most useful when tracked over time:\n\n- Set a baseline by observing throughput over 30 days\n- Watch for sustained drops that may indicate process problems\n- Compare throughput before and after process changes\n- Use agent-level throughput to balance workload across your team",
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
              "Cycle time measures the duration from when a task is **claimed** (work begins) until it is **completed**. It answers the question: \"How long does it take to finish a task once we start working on it?\"\n\nShorter cycle times mean faster delivery and quicker feedback loops.",
            image: nil
          },
          %{
            title: "Navigate to Cycle Time",
            content:
              "From the metrics dashboard, click **Cycle Time** to see the detailed view. You can also navigate directly from the board by going to **Metrics → Cycle Time**.",
            image: "/images/resources/guides/cycle-time-summary.png"
          },
          %{
            title: "Reading the Chart",
            content:
              "The cycle time chart shows how long completed tasks took. Look for:\n\n- **Average cycle time**: Your typical delivery speed\n- **Outliers**: Tasks that took much longer than usual may indicate blockers or unclear requirements\n- **Trends**: Is cycle time improving, stable, or getting worse over time?\n\nFilter by agent to identify differences in working speed across your team.",
            image: "/images/resources/guides/cycle-time-chart.png"
          },
          %{
            title: "Reducing Cycle Time",
            content:
              "To improve cycle time:\n\n- Write clearer task descriptions and acceptance criteria\n- Break large tasks into smaller, focused pieces\n- Remove blockers and dependencies where possible\n- Ensure tasks have all the context needed to start immediately\n- Review the relationship between task complexity and actual cycle time to improve estimates",
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
              "Lead time measures the total duration from when a task is **created** until it is **completed**. Unlike cycle time, lead time includes the time a task spends waiting in the backlog before work begins.\n\nLead time answers the question: \"How long does it take from the moment we identify a need until it's delivered?\"",
            image: nil
          },
          %{
            title: "Navigate to Lead Time",
            content:
              "From the metrics dashboard, click **Lead Time** to see the detailed view. You can also navigate directly from the board by going to **Metrics → Lead Time**.",
            image: "/images/resources/guides/lead-time-summary.png"
          },
          %{
            title: "Lead Time vs. Cycle Time",
            content:
              "Understanding the difference is key:\n\n- **Lead Time** = Wait time in backlog + Cycle time + Review time\n- **Cycle Time** = Only the active working time\n\nA large gap between lead time and cycle time means tasks are spending a lot of time waiting. This is an opportunity to improve prioritization or increase capacity.",
            image: "/images/resources/guides/lead-time-chart.png"
          },
          %{
            title: "Reducing Lead Time",
            content:
              "To improve lead time:\n\n- Prioritize your backlog regularly so important tasks don't sit idle\n- Keep the Ready column small — only add tasks that can start soon\n- Speed up reviews to reduce time in the Review column\n- Monitor the gap between lead time and cycle time to identify where delays occur",
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
              "Wait time measures how long tasks spend **idle** — not being actively worked on. Stride tracks two types:\n\n- **Backlog Wait**: Time from task creation until an agent claims it\n- **Review Wait**: Time from task completion until a reviewer approves it\n\nWait time reveals bottlenecks in your workflow that slow down delivery.",
            image: nil
          },
          %{
            title: "Navigate to Wait Time",
            content:
              "From the metrics dashboard, click **Wait Time** to see the detailed view. You can also navigate directly from the board by going to **Metrics → Wait Time**.",
            image: nil
          },
          %{
            title: "Reading the Tables",
            content:
              "The wait time tables show both backlog wait and review wait. Look for:\n\n- **High backlog wait**: Tasks are created but not being picked up — you may need more agents or better prioritization\n- **High review wait**: Completed work is stuck waiting for approval — reviewers may be a bottleneck\n- **Trends**: Are wait times improving or getting worse over time?",
            images: [
              %{
                url: "/images/resources/guides/review-wait-time.png",
                alt: "Review Wait Time"
              },
              %{
                url: "/images/resources/guides/backlog-wait-time.png",
                alt: "Backlog Wait Time"
              }
            ]
          },
          %{
            title: "Reducing Wait Time",
            content:
              "To reduce backlog wait:\n\n- Keep the backlog prioritized so agents always have clear next tasks\n- Ensure tasks have complete descriptions so agents can start immediately\n- Match task capabilities to available agents\n\nTo reduce review wait:\n\n- Set aside regular time for reviewing completed work\n- Consider setting `needs_review: false` for low-risk tasks\n- Use notifications to stay informed when tasks enter review",
            image: nil
          }
        ]
      }
    ]
  end
end
