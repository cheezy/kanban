defmodule KanbanWeb.ResourcesLive.HowTos.Organizations do
  @moduledoc """
  Guides for free and paid boards, Organization workspaces and invitations.

  One of the data modules `KanbanWeb.ResourcesLive.HowToData` concatenates,
  in order, into the Resources catalog. All three guides lead with the
  `organizations` tag, so navigation runs free and paid boards → working in a
  workspace → accepting an invitation, then on into the org-admin guides in
  `HowTos.OrgAdmin`, which lead with the same tag.

  The free/paid guide follows `Kanban.Plans`, the `LockedFeature` component
  and the board members screen's free-board limit. The workspace guide follows
  the workspace switcher and the `/workspace/settings` tabs
  (`WorkspaceLive.Settings` and its cards). The invitation guide follows
  `WorkspaceLive.InvitationAccept`. `docs/organizations.md` is the technical
  reference behind all three.
  """

  @doc "The guides in this group, in display order."
  def how_tos do
    [
      %{
        id: "free-and-paid-boards",
        title: "Free and Paid Boards",
        description:
          "What makes a board paid, the three-person limit on free boards, and the features that show \"Available to organizations\".",
        tags: ["organizations", "boards"],
        content_type: "guide",
        reading_time: 5,
        created_at: ~D[2026-10-24],
        steps: [
          %{
            title: "What Makes a Board Paid",
            content:
              "A board is paid when it is in one of an Organization's workspaces. Every other board is free: the boards you create for yourself live in your personal workspace, and they stay free even if you belong to an Organization.\n\nWhat you can use depends on two things: whether you belong to an Organization, and whether the board is paid.",
            image: nil
          },
          %{
            title: "When Plans Apply",
            content:
              "The limits in this guide apply only when your Stride instance switches its plans on. If plans are off, as they can be on a Stride you run yourself, every board works like a paid board: there is no member limit and nothing shows a lock.\n\nTo compare what each plan includes, see [Pricing](/pricing).",
            image: nil
          },
          %{
            title: "The Free-Board Limit",
            content:
              "A free board holds up to 3 people. The owner counts as one of them, and so do read-only members and disabled accounts. AI agents don't count, because they work through API tokens rather than seats.\n\nThe board's **Members** window shows how many seats are in use. When a board is full, Stride refuses to add or invite anyone else, and the window offers **Get Stride for your organization**.\n\nA board that already had more than 3 people when the limit started keeps all of them, as in the picture. Removing people always works, but nobody new can join until it is below the limit. [Inviting Team Members](/resources/inviting-team-members) covers adding people.",
            image: "/images/resources/guides/free-and-paid-boards-step-3.png",
            image_width: 593,
            image_height: 162
          },
          %{
            title: "Locked Features on a Board",
            content:
              "On a free board, some features show a lock and **Available to organizations** instead of working:\n\n- **Bulk actions**: selecting several tasks to move, label or archive them at once.\n- **Telemetry**: the telemetry fields in a task's Observability section.\n- **MCP**: AI clients that connect to the board over MCP get a plan-required error instead of an answer.\n\nIntegrations are locked too (next step). Tasks, columns and members work as usual.",
            image: "/images/resources/guides/free-and-paid-boards-step-4.png",
            image_width: 1132,
            image_height: 114
          },
          %{
            title: "Integrations and Notifications",
            content:
              "**Integrations** (webhooks and Slack or Discord messages) need a paid board. On a free board the Integrations window shows the lock and sends nothing. Endpoints already on the board are kept, and the switched-on ones are marked Paused until the board moves into an Organization.\n\n**Notifications** need you to belong to an Organization, and they come only from paid boards. Without an Organization, your notifications page shows the lock, but tasks waiting for you are still listed in the **Review queue** and **My Work**.",
            image: "/images/resources/guides/free-and-paid-boards-step-5.png",
            image_width: 609,
            image_height: 228
          },
          %{
            title: "Getting Organization Features",
            content:
              "Click **Available to organizations** next to any lock to reach **Get Stride for your organization** on the [Pricing](/pricing) page, where **Talk to us** emails the Stride team. Stride's admins set up Organizations, so there is no button for you to create one.\n\nOnce you belong to an Organization, single sign-on and workspaces unlock for you. Bulk actions, integrations, telemetry, MCP and notifications also depend on the board, so they stay locked on the boards in your personal workspace.",
            image: nil
          },
          %{
            title: "Making a Board Paid",
            content:
              "To make a free board paid, an org-admin who owns it moves it into one of the Organization's workspaces with **Move a board here**. Everyone on the board must already belong to the Organization, and a board can't be moved back. [Working in a Workspace](/resources/working-in-a-workspace) walks through it.",
            image: nil
          }
        ]
      },
      %{
        id: "working-in-a-workspace",
        title: "Working in a Workspace",
        description:
          "Switch between your Organization's workspaces, see who is in each one, and, as an org-admin, invite people, move boards in and export a workspace.",
        tags: ["organizations", "workspaces"],
        content_type: "guide",
        reading_time: 7,
        created_at: ~D[2026-10-24],
        steps: [
          %{
            title: "Workspaces and Your Organization",
            content:
              "An Organization groups its boards into workspaces, such as one per team. Each workspace has its own members and boards, and every board in it is a paid board.\n\nBeing in a workspace doesn't open its boards for you. You see a board once you are a member of that board, or if you are an org-admin, who sees them all.",
            image: nil
          },
          %{
            title: "Switching Workspaces",
            content:
              "If you belong to an Organization, the workspace switcher sits at the top of the sidebar, showing the workspace you are in. Open it to see your workspaces, and click one to switch. Stride then opens **Boards** for that workspace.\n\nAn org-admin sees every workspace in the Organization. Everyone else sees only the workspaces they have been added to. Your personal boards are not in the list; they stay on the **Boards** page in every workspace.\n\nWhen plans are on, someone who doesn't belong to an Organization sees **Workspaces** with a lock in this spot instead.",
            image: "/images/resources/guides/working-in-a-workspace-step-2.png",
            image_width: 150,
            image_height: 293
          },
          %{
            title: "Opening Workspace Settings",
            content:
              "Click **Workspace settings** in the switcher. Everyone in the workspace sees two tabs:\n\n- **Members**: who is in the workspace, with their email and role.\n- **Boards**: the workspace's boards you can see.\n\nOrg-admins also see **Invitations**, **Tokens** and **Export**, and can change roles and remove people. For everyone else these pages are read-only.",
            image: "/images/resources/guides/working-in-a-workspace-step-3.png",
            image_width: 1189,
            image_height: 361
          },
          %{
            title: "Member or Guest",
            content:
              "Everyone in a workspace is a **Member** or a **Guest**:\n\n- A Member can create boards in the workspace. A board you create while the workspace is selected goes into it.\n- A Guest works on the boards they are invited to, but can't create boards there. A board a Guest creates goes into their personal workspace.\n\nAn org-admin changes a role with the role list and **Save**. **Remove** takes someone out of the workspace, which also removes them from its boards and revokes their API tokens for it. Organization roles, such as who is an org-admin, are managed by Stride's admins, not here.",
            image: nil
          },
          %{
            title: "Moving a Board Here",
            content:
              "On **Boards**, an org-admin sees every board in the workspace and the **Move a board here** card. Choose one of your personal boards and click **Move here**.\n\nYou can move a board only if you own it and everyone on it already belongs to the Organization. If someone doesn't, Stride names them, so you can remove them from the board or invite them to the workspace first. The members keep their access, and the board becomes paid. A board can't be moved back, or from one workspace to another.",
            image: "/images/resources/guides/working-in-a-workspace-step-5.png",
            image_width: 981,
            image_height: 335
          },
          %{
            title: "Inviting People",
            content:
              "On **Invitations**, an org-admin fills in **Invite people**: the **Email**, the **Role**, and optionally a board from **Board (optional)** with its **Board access** (**Read only** or **Can edit**). Click **Send invitation**, and Stride emails a link that works once and expires in 7 days.\n\nAccepting makes the person a member of the Organization and of this workspace. Each person can belong to one Organization.\n\n**Pending invitations** lists the links nobody has used yet. **Resend** sends a new link and stops the old one; **Revoke** stops the link for good. [Accepting an Invitation](/resources/accepting-an-invitation) shows what the person sees.",
            image: "/images/resources/guides/working-in-a-workspace-step-6.png",
            image_width: 981,
            image_height: 446
          },
          %{
            title: "Workspace Tokens",
            content:
              "On **Tokens**, an org-admin can **Create a workspace token**: one API token for every AI Optimized board in the workspace that you can modify, so an agent doesn't need a token per board. It acts as you and expires in 90 days. [Setting Up API Authentication](/resources/api-authentication) explains how agents use it.",
            image: nil
          },
          %{
            title: "Exporting a Workspace",
            content:
              "On **Export**, an org-admin clicks **Request export** to get a zip archive of the workspace's boards, columns, labels, tasks, comments, history and memberships, for a backup or to move to another Stride instance.\n\nStride prepares it in the background, so you can leave the page. When it is ready, click **Download**. Archives are kept for 7 days, and only org-admins can download them.",
            image: "/images/resources/guides/working-in-a-workspace-step-8.png",
            image_width: 981,
            image_height: 309
          },
          %{
            title: "When Someone Leaves",
            content:
              "When an org-admin removes someone from a workspace, they lose its boards and their API tokens for it straight away. A workspace token stops working when the org-admin it acts as leaves the workspace or the Organization.\n\nChanging a Member to a Guest also revokes any open invitation sent to that person in the workspace, so an old link can't make them a Member again.",
            image: nil
          }
        ]
      },
      %{
        id: "accepting-an-invitation",
        title: "Accepting an Invitation",
        description:
          "Open the link from an invitation email, join a workspace or a board, and find out what to do when a link doesn't work.",
        tags: ["organizations", "workspaces", "beginner"],
        content_type: "guide",
        reading_time: 4,
        created_at: ~D[2026-10-24],
        steps: [
          %{
            title: "Two Kinds of Invitation",
            content:
              "Stride sends two kinds of invitation by email:\n\n- From an org-admin, to join a workspace and its Organization, sometimes with access to one board.\n- From a board's owner, to join just that board. This happens when they invite an email address that has no account yet; see [Inviting Team Members](/resources/inviting-team-members).\n\nEither way, the email holds a link that works once and expires after 7 days.",
            image: nil
          },
          %{
            title: "Opening the Link Without an Account",
            content:
              "If you aren't signed in, the link opens **You're invited**.\n\n- New to Stride? Click **Create account** and sign up with the same email address the invitation went to. The invitation is accepted when you confirm your email.\n- Already have an account? Click **Sign in**, then open the link from the email again.",
            image: "/images/resources/guides/accepting-an-invitation-step-2.png",
            image_width: 466,
            image_height: 247
          },
          %{
            title: "Accepting",
            content:
              "Signed in with the invited email address, the link shows what you are joining, such as the workspace and its Organization, or the board. Nothing changes until you click **Accept invitation**.\n\nStride then opens the board you were given, or your **Boards** page if the invitation had no board.",
            image: nil
          },
          %{
            title: "When the Link Doesn't Work",
            content:
              "**Invitation unavailable** means the link can't be used. This happens when it has expired, was revoked or resent, or was already used, or, for a workspace invitation, when you already belong to a different Organization.\n\nIf you are signed in with another account, the page shows the email you are signed in as, with **Log out**. Sign out, sign in with the invited address, and open the link again. Otherwise, ask the person who invited you to send a new invitation.",
            image: "/images/resources/guides/accepting-an-invitation-step-4.png",
            image_width: 466,
            image_height: 143
          },
          %{
            title: "When a Free Board Is Full",
            content:
              "When plans are on, a free board holds 3 people. If the board filled up after you were invited, clicking **Accept invitation** shows **This board is full**. Your invitation stays open, so ask the board owner to make room, then open the link again before it expires.",
            image: nil
          },
          %{
            title: "After You Join",
            content:
              "If you joined a workspace, you are now a member of its Organization. The workspace switcher appears at the top of the sidebar, and **Workspace settings** shows who else is in the workspace. [Working in a Workspace](/resources/working-in-a-workspace) explains what you can do there.\n\nIf you joined a single board, it appears on your **Boards** page with the others.",
            image: nil
          }
        ]
      }
    ]
  end
end
