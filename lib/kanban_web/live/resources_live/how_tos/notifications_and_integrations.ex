defmodule KanbanWeb.ResourcesLive.HowTos.NotificationsAndIntegrations do
  @moduledoc """
  Guides for keeping up with a board without watching it: notifications,
  webhook, Slack and Discord endpoints, and connecting an MCP client.

  One of the data modules `KanbanWeb.ResourcesLive.HowToData` concatenates,
  in order, into the Resources catalog. It sits after
  `HowTos.AgentsAndPlanning` and before `HowTos.Metrics`.

  The notifications and integrations guides lead with their own tags and
  carry each other's, so they navigate as a pair. The MCP guide leads with
  `developer`, so it ends that chain: setting up hooks → API authentication →
  the claim/complete workflow → debugging hooks → connecting an MCP client.

  The guides follow `KanbanWeb.NotificationBell`, `KanbanWeb.NotificationLive.Index`,
  `KanbanWeb.UserLive.NotificationPreferences`, `Kanban.Notifications`, the
  board's Integrations window (`KanbanWeb.BoardLive.IntegrationsComponent`),
  `Kanban.Webhooks` and `KanbanWeb.MCP.Server`.
  """

  @doc "The guides in this group, in display order."
  def how_tos do
    [
      %{
        id: "staying-informed-with-notifications",
        title: "Staying Informed With Notifications",
        description:
          "What Stride notifies you about, the bell and the notifications page, choosing what reaches you, the weekly digest, and unsubscribing from email.",
        tags: ["notifications", "integrations", "monitoring"],
        content_type: "guide",
        reading_time: 6,
        created_at: ~D[2026-10-24],
        steps: [
          %{
            title: "What Notifies You",
            content:
              "Stride notifies you when something on your boards needs you:\n\n- **Review requests**: a task reaches Review. The board's owner and every member with edit access are told.\n- **Review results**: a reviewer approves your task or asks for changes. The person who completed the task is told, or its assignee.\n- **Task assignments**: someone else assigns a task to you.\n- **Unclaimed tasks**: an agent releases a task. The person whose token released it and the task's creator are told.\n- **Expired claims**: an agent's claim on your task runs out before the work is done.\n- **Completed goals** and **After-goal hook failures**: for the goal's creator and its assignee.\n- **Delivery target status**: a target you own becomes at risk or misses its date.\n- **Board access changes**: someone else adds you to a board, removes you, or changes your access.\n- **Mentions**: someone mentions you in a comment, as [Commenting and Mentioning](/resources/commenting-and-mentioning) explains.\n\n**Comments** also has a row in your preferences, but a comment with no mention notifies nobody.",
            image: nil
          },
          %{
            title: "Notifications and Plans",
            content:
              "When Stride's plans are switched on, notifications need two things. You need to belong to an Organization to see the bell's count, read your notifications, get email and change your preferences. The board has to be in an Organization too: a free board sends no notifications at all, even to Organization members.\n\nWithout an Organization, the bell shows a lock and the notifications page says **Available to organizations**. Tasks waiting for you are still listed in the **Review queue** and **My Work**.\n\nWhen plans are switched off, everyone gets every notification. [Free and Paid Boards](/resources/free-and-paid-boards) explains plans.",
            image: nil
          },
          %{
            title: "The Bell",
            content:
              "The bell at the top of the page shows how many notifications you haven't read, up to 99; above that it shows 99+. The count updates as notifications arrive, without reloading the page. Click the bell to open your notifications.",
            image: "/images/resources/guides/staying-informed-with-notifications-step-3.png",
            image_width: 418,
            image_height: 95
          },
          %{
            title: "The Notifications Page",
            content:
              "**Notifications** lists the newest first, 25 at a time; **Load more** shows the next 25. Switch between **All** and **Unread** at the top.\n\nEach notification shows what kind it is, what happened, who did it and how long ago. An orange dot marks one you haven't read. Click a notification to open the task or page it's about, which also marks it read. **Mark as read** marks one without opening it, and **Mark all read** marks every one.",
            image: "/images/resources/guides/staying-informed-with-notifications-step-4.png",
            image_width: 1179,
            image_height: 481
          },
          %{
            title: "Choosing What Reaches You",
            content:
              "Open your settings and click **Notifications** to reach **Notification preferences**. The events are grouped under **Reviews**, **Tasks and agents**, **Goals and targets**, **Board access** and **Comments and mentions**.\n\nEach event has an **In-app** switch for the bell and the notifications page, and an **Email** switch. A change saves as soon as you make it.\n\nEverything is on until you change it, except the email for **Completed goals** and **Comments**. While plans are switched on, only Organization members can change their preferences.",
            image: "/images/resources/guides/staying-informed-with-notifications-step-5.png",
            image_width: 1158,
            image_height: 711
          },
          %{
            title: "The Weekly Digest",
            content:
              "Under **Weekly digest**, **Email me a weekly summary of activity on my boards** is on by default. The digest is sent on Mondays at 13:00 UTC and covers the week before: the tasks done, the goals completed and the tasks waiting for review, board by board.\n\nA week with nothing to report sends no email. The digest arrives only by email, never in the bell. While plans are switched on, it counts only boards in an Organization.",
            image: nil
          },
          %{
            title: "Unsubscribing From Email",
            content:
              "Every notification email ends with **Unsubscribe from these emails** and **Manage notification preferences**.\n\nThe unsubscribe link opens a page that asks you to confirm; click **Unsubscribe** to stop that kind of email. You don't need to sign in. It turns off email for that one event only, and **In-app notifications are not affected.** The link works for 90 days, and unsubscribing never needs a paid plan.\n\nIf your mail app shows its own unsubscribe button, it does the same in one click.",
            image: nil
          }
        ]
      },
      %{
        id: "connecting-webhooks-slack-and-discord",
        title: "Connecting Webhooks, Slack and Discord",
        description:
          "Send a board's task events to your own service as signed webhooks, or as messages in a Slack or Discord channel.",
        tags: ["integrations", "notifications", "automation"],
        content_type: "guide",
        reading_time: 8,
        created_at: ~D[2026-10-24],
        steps: [
          %{
            title: "Who Can Set Up Integrations",
            content:
              "Only the board's owner sees the **Integrations** tab, next to **Settings**; an org-admin counts as the owner of their Organization's boards. Members can't open it, even with edit access. It works on every kind of board.\n\nWhen Stride's plans are switched on, integrations need the board to be in an Organization. On a free board the window says **Available to organizations**, every endpoint offers only **Deliveries** and **Delete**, and nothing is sent. Endpoints that are switched on show **Paused** and start sending again once the board moves into an Organization; a disabled endpoint stays off until you enable it. [Free and Paid Boards](/resources/free-and-paid-boards) explains plans.",
            image: nil
          },
          %{
            title: "Adding an Endpoint",
            content:
              "Click **Integrations** to open the window, then fill in **Add an endpoint**:\n\n- **Kind**: **Generic webhook** sends a signed JSON request to your own service. **Slack** and **Discord** post a message in a channel.\n- **URL**: an https address that reaches the public internet. For Slack, paste an incoming webhook URL from `hooks.slack.com`; for Discord, the webhook URL you copied from the channel's settings.\n- **Events**: the task events to send, such as `task.created`, `task.moved_to_review` and `task.completed`. Pick at least one.\n\nClick **Add endpoint**. A board can have as many endpoints as you need.",
            image: "/images/resources/guides/connecting-webhooks-slack-and-discord-step-2.png",
            image_width: 574,
            image_height: 247
          },
          %{
            title: "Managing Endpoints",
            content:
              "Each endpoint shows its kind, the host it sends to, its events and who added it. The full URL is never shown again, because a Slack or Discord URL works like a password.\n\n- **Edit** changes the URL or the events. The kind can't change, and leaving the URL blank keeps the current one.\n- **Disable** stops sending without losing the endpoint; **Enable** starts it again.\n- **Delete** removes the endpoint and its delivery log.\n\nIf the person who added an endpoint loses access to the board, it switches off. Enabling it again makes you its owner. **Not sending** means the account that added it has been disabled.",
            image: "/images/resources/guides/connecting-webhooks-slack-and-discord-step-3.png",
            image_width: 597,
            image_height: 496
          },
          %{
            title: "The Signing Secret",
            content:
              "A generic webhook signs every request. Right after you add one, the window shows its **Signing secret**, starting with `whsec_`, once. Click **Copy** and store it with your service; you can't see it again.\n\n**Rotate secret** replaces the secret, and the old one stops working at once. Use it if the secret leaks or the endpoint moves to a different service. Slack and Discord messages aren't signed, so those endpoints have no secret.",
            image: "/images/resources/guides/connecting-webhooks-slack-and-discord-step-4.png",
            image_width: 574,
            image_height: 257
          },
          %{
            title: "Testing and the Delivery Log",
            content:
              "**Send test** sends a `ping` event to an enabled endpoint. Click **Deliveries** to open **Recent deliveries**, and **Refresh** to see new attempts.\n\nThe log shows the 20 most recent attempts, with the **Event**, **Status** (**Succeeded**, **Failed** or **Pending**), the **Attempt** number, the **Response** code, any **Error** and the **Time**. Each retry gets its own row.\n\nA failed delivery is retried, up to 8 attempts over about an hour. A 4xx response isn't retried, except 408 and 429.",
            image: "/images/resources/guides/connecting-webhooks-slack-and-discord-step-5.png",
            image_width: 574,
            image_height: 348
          },
          %{
            title: "Verifying Signatures",
            content:
              "Each generic request carries `X-Stride-Event`, `X-Stride-Delivery` (the same on every retry, so you can skip duplicates) and `X-Stride-Signature`, which looks like `t=1767225600,v1=5257a869…`.\n\nTo check it, compute an HMAC-SHA256 of the timestamp, a full stop and the raw request body, keyed with your signing secret, and compare it with `v1` in constant time. Reject a timestamp more than 5 minutes old. Reply with a 2xx within 10 seconds.\n\nThe [webhooks reference](https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/webhooks.md) has the payloads and verification code in Python and Node.",
            image: nil
          }
        ]
      },
      %{
        id: "connecting-an-mcp-client",
        title: "Connecting an MCP Client",
        description:
          "Point Claude Code or another MCP client at Stride's MCP server so an agent can find, claim and complete tasks through tools.",
        tags: ["developer", "api", "automation"],
        content_type: "guide",
        reading_time: 5,
        created_at: ~D[2026-10-24],
        steps: [
          %{
            title: "What the MCP Server Offers",
            content:
              "Stride's MCP server gives an agent the same claim and complete loop as the REST API, as six tools: `stride_next_task`, `stride_claim_task`, `stride_complete_task`, `stride_get_task`, `stride_list_tasks` and `stride_add_comment`. Your hooks still run on your machine, as [Understanding Claim/Complete Workflow](/resources/claim-complete-workflow) explains.\n\nEverything else, such as creating tasks and goals, stays on the REST API.",
            image: nil
          },
          %{
            title: "A Token and a Paid Board",
            content:
              "The MCP server uses the same API tokens as the REST API; [Configuring API Authentication](/resources/api-authentication) shows how to create one. A board token works on its board. A workspace token also needs the board's ID in an `X-Stride-Board` header on each tool call.\n\nWhen Stride's plans are switched on, the board has to be in an Organization. On a free board every call returns error `-32001`, and the REST API keeps working. [Free and Paid Boards](/resources/free-and-paid-boards) explains plans.",
            image: nil
          },
          %{
            title: "Adding Stride to Claude Code",
            content:
              "Put your token in an environment variable, then add the server:\n\n```bash\nexport STRIDE_API_TOKEN=\"paste-your-token-here\"\nclaude mcp add --transport http stride https://www.stridelikeaboss.com/api/mcp \\\n  --header \"Authorization: Bearer ${STRIDE_API_TOKEN}\"\n```",
            image: nil
          },
          %{
            title: "Or Use a Project .mcp.json",
            content:
              "To share the setup with a project, add a `.mcp.json` at its root. Claude Code fills in `${STRIDE_API_TOKEN}` from your environment, so the token itself is never committed:\n\n```json\n{\n  \"mcpServers\": {\n    \"stride\": {\n      \"type\": \"http\",\n      \"url\": \"https://www.stridelikeaboss.com/api/mcp\",\n      \"headers\": {\n        \"Authorization\": \"Bearer ${STRIDE_API_TOKEN}\"\n      }\n    }\n  }\n}\n```",
            image: nil
          },
          %{
            title: "Checking the Connection",
            content:
              "In Claude Code, run `/mcp`: Stride should be connected with six tools.\n\nOther clients work if they speak Streamable HTTP and can send an `Authorization` header. The server answers each POST with JSON and offers no event stream, so a client that needs one won't connect. The [MCP reference](https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/MCP.md) has the details.",
            image: nil
          }
        ]
      }
    ]
  end
end
