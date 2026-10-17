# Paying organizations and free-tier limits for Stride

*Date: 2026-10-17 15:44*
*Session: 2026-10-17T154403-paying-organizations-and-free-tier-limits-for-stride*

## Problem

Stride earns nothing today. Every user gets every feature, any board can have any number of users, and there is nothing a company can buy: no organization, no central administration, no SSO and no organization-level audit. The two customers most likely to pay have no paid path. One is the engineering team lead running AI agents across several boards, who needs more people per board, one admin view and MCP access. The other is the company IT or security buyer, who won't approve a tool without SSO, audit logs and central user control. Meanwhile `/pricing` advertises a Team plan with a free trial that the product cannot deliver.

## Goal

Start earning from teams. Companies pay for team and governance features through an Organization, while individuals and small groups keep using Stride for free.

## Success metrics

- **leading indicators** (observable while the work is in flight, predict the outcome):
  - Weekly clicks on the "Available to organizations" prompt, broken down by locked feature (Notifications, Audit, SSO, Workspaces, Bulk actions, Integrations, Telemetry, MCP), from launch onward.
- **lagging indicators** (the outcome itself, observable only after it has occurred):
  - At least 5 paying Organizations created and active within 6 months of launch.

## Assumptions

*Ordered highest to lowest risk; the riskiest entry is marked `(R)`. Each entry carries the challenge gate's confidence rating.*

- Active free users will accept losing Notifications, MCP, Bulk actions and webhooks at launch rather than leave, and the losses will not outweigh the Organizations gained. This is the premortem's most likely failure. (R) (low)
- A sales-led, manually onboarded process can reach enough team leads and IT buyers to sign 5 Organizations in 6 months, drawn by the paid features. (low)
- Every paid-only feature can be closed at every entry point (UI, REST API, MCP endpoint, existing API tokens, direct URLs, background emails and jobs), so no side door undercuts the reason to pay. This is a premortem risk. (medium)
- Moving existing users and boards into the new structure (hidden personal workspaces) and applying the 3-user cap takes no one's current access away. This is a premortem risk. (medium)
- AI agents don't count toward the cap. Only human board members do, because agents act through an existing user's API token and are not board members. (high)

## Constraints

- Every existing user starts as a free (non-paying) user.
- Free boards are unlimited in number, but each has at most 3 human users.
- **Paid status follows the board.** Paid features work on boards in an Organization's workspace. An Organization member's personal boards stay free: they keep the 3-user cap and the locked features.
- A user belongs to at most one Organization.
- Only a Stride admin (site admin) can create an Organization and create its org-admins.
- Boards that already exceed the cap at launch are grandfathered: no member is removed, but no one can be added until the board is under the cap or moves into an Organization.
- Paid-only features lock for free boards on launch day, announced beforehand, with no grace period.
- "Notifications" means Stride's notification feature: the in-app bell, notification emails and digests. Account emails (password reset, email confirmation, two-factor) stay available to everyone.
- A free agent's REST create or complete call that includes task telemetry fields (`telemetry_event`, `metrics_to_track`) still succeeds. The fields are not stored, and the response warns that they need an Organization, so free agents keep working.
- Organization data is limited to name, address and a contact (name, phone, email).
- Becoming a paying customer happens outside Stride: the sale and invoicing are handled off-platform, and a Stride admin then sets the customer up.
- **Launch is everything at once.** All six decomposition seams ship before launch: Organizations, the plan check and cap, the feature locks, workspaces, SSO and Organization audit, and the public pages. The 6-month window for the lagging metric starts at that launch.
- The work builds on the G442 workspace design (`docs/ideation/2026-10-17T112210-g442-workspaces-ui-briefing.md`), and every legacy board access value must keep working.

## Non-goals

- **Payments and invoicing.** There is no Stripe, checkout, trial, invoice or seat billing, because sales are handled manually. Removed task W2223 stays removed.
- **Self-serve Organization creation or upgrade.** Only a Stride admin creates Organizations, which keeps the paid path sales-led and controlled.
- **Organization seat limits and plan tiers beyond free and paid.** There are two plans; organizations have no caps on users or boards. The extra pricing complexity isn't justified before the first 5 customers.
- **Downgrading an Organization to free.** There is no automated path for a lapsed contract. A Stride admin handles any such case by hand for now.
- **Locking the metrics pages.** Board metrics pages and their exports stay free. "Telemetry" refers only to the task telemetry fields.
- **Locking the REST API.** Only the `/api/mcp` endpoint is paid-only, so free users' agents keep claiming and completing tasks through the REST API.

## Outcome

After this ships:
- **Plans.** Stride has two kinds of customer. Free users keep unlimited boards with up to 3 human users each. Paying customers are ordinary users who belong to an **Organization**.
- **Setup.** A Stride admin creates the Organization (name, address, contact name, phone and email) and its **org-admins**.
- **Structure.** Each Organization holds the workspaces from the G442 design, and boards sit inside those workspaces. Org-admins take the role G442 gave workspace admins: they manage members, roles, invitations, workspace tokens and exports, and they can reach every workspace and board in their Organization.
- **Paid-only features.** Notifications, Audit (an organization-scoped audit log for org-admins), SSO, Workspaces, Bulk actions, Integrations (board webhooks), Telemetry (task telemetry fields) and MCP access are available on boards in an Organization's workspaces. On free boards each feature is still visible, locked, with an "Available to organizations" prompt, and those clicks are counted.
- **Free users' boards.** Each free user has a hidden personal workspace that holds their boards, so every board still belongs to a workspace.
- **Moving a board into an Organization.** An org-admin who owns a free board can move it into one of their workspaces. This lifts the cap, unlocks the paid features on it, and ends any grandfathering.
- **Stride's own boards** run inside an internal Organization from launch.
- **Public pages.** `/pricing`, `/terms` and `/privacy` describe the free plan and a sales-led Organization plan instead of a self-serve Team trial.

## Concrete Example

Priya leads a platform team and uses Stride on a free account. She has six boards and an agent fleet working them through the REST API.
- **Trigger.** She tries to add a fourth engineer to her busiest board, and the board refuses: free boards hold 3 people. The same day she notices that Notifications, Bulk actions and MCP show locks reading "Available to organizations".
- **Today (bad path).** She would create duplicate boards to get around the limit, and she has nothing to show her company's IT team, who require SSO and audit logs.
- **After (good path).** She clicks the prompt and contacts Stride. After the deal is signed off-platform, a Stride admin creates "Acme Platform" with Priya as org-admin. Priya moves her six boards into an "Engineering" workspace, which lifts the cap and unlocks the paid features on those boards. She invites her team by email, sets up SSO for the IT team, and points the security reviewer at the Organization audit log. Her agents keep working throughout, and gain MCP access.

## Sketch

- **New entities.**
  - `organizations` holds name, address, and contact name, phone and email.
  - An organization membership links users to Organizations (at most one per user) and carries the org-admin role.
  - Workspaces gain an optional organization reference. Personal workspaces stay without one and are hidden from free users.
- **A single plan check.** One function decides whether a board is paid: is its workspace owned by an Organization? Every paid-only feature, at every entry point, goes through this one check.
  - Features that aren't tied to a single board resolve per board. The notification bell shows only events from paid boards, and an MCP request is allowed only for a paid board.
- **Cap enforcement** happens in the board-membership path (adding a member and accepting an invitation). It counts human members, exempts grandfathered boards from removal, and blocks additions while a board is over the cap.
- **Stride admin screens** under `/admin` to create Organizations, edit their details, and appoint or remove org-admins.
- **Changes to existing work.**
  - G442's workspace-admin role becomes org-admin, and personal workspaces become hidden for free users.
  - Workspaces themselves are paid-only.
  - The existing SSO goal (Goal 6: SSO, SCIM, audit) is scoped to Organizations, and its audit part becomes the Organization audit log.
- **Launch.** A migration marks every existing user as free and records which boards are over the cap. Feature locks switch on at launch. An internal Organization is created for Stride's own boards.

## Open questions

- Where is the org-admin role stored: on a new organization membership (preferred, and in line with W2216's rule against reusing `User.type`), or as a new `User.type` value?
- What exactly happens at the launch cutoff for each feature, so locking stays recoverable:
  - which message a free user's MCP client receives;
  - whether existing board webhooks are paused (configuration kept) or deleted;
  - whether undelivered notifications are dropped;
  - how free reviewers learn that tasks are waiting in Review once notification emails stop.
- What counts as "using" a locked feature, for the clicks metric and for the announcement before launch.
- Whether an org-admin can move a board they don't own, for example one owned by a teammate who is already in the Organization.

## Design challenge

- **Blind spots:**
  - **G442 changes.** G442 assumed every user's personal workspace was visible and that workspaces were free. Its schema and moving-boards-into-workspaces tasks (W2216, W2217) need reworking for hidden personal workspaces and Organization-owned workspaces.
  - **Moving boards.** Converting grandfathered teams depends on a board-move flow that no current task provides.
  - **Effects of the launch cutoff:**
    - review-request emails stop for free reviewers, so tasks may sit in Review unnoticed;
    - free users' MCP agents break mid-session;
    - existing webhooks on free boards stop sending.
  - **Stride's own boards** would lose features without an internal Organization.
  - **Public pages.** `/pricing`, `/terms` and `/privacy` promise a self-serve Team trial and self-service deletion that the sales-led model must describe differently.
- **Alternative A (phased):** ship the Organization, org-admins, the cap and feature locks first, and defer workspaces and SSO to a second phase. It has the same end state and an earlier first sale to team leads, but the IT buyer's SSO requirement waits.
- **Alternative B (per-user Pro plan):** paying individuals unlock features on their own boards, with no Organization entity. It is the simplest and fastest, but it does not serve the company buyer and would be reworked once Organizations arrive.
- **Trade-off comparison:**

  | | Proposed (everything at once) | A (phased) | B (per-user Pro) |
  |---|---|---|---|
  | Cost | Highest | Medium | Lowest |
  | Risk | Highest (the scope could slip past the 6-month window) | Medium | Low now, high rework later |
  | Complexity | Org, workspaces, SSO, audit and locks together | Org and locks, then the rest | A user flag and locks |
  | Time to first sale | Longest | Shortest for team leads | Short, but no company buyers |

  The proposed design was kept deliberately: the whole program ships together before launch, decomposed into one goal per seam.

## Decomposition seams

1. **Organizations and org-admins.** Organization schema and membership, the org-admin role, and the Stride admin screens to create Organizations and appoint org-admins.
2. **Plan check and free-tier cap.** The single board-level plan check, the 3-human-user board cap with grandfathering, the launch migration, and the internal Organization.
3. **Paid feature locks.** Locks and "Available to organizations" prompts for Notifications, Bulk actions, Integrations (webhooks), Telemetry (task fields, accepted but not stored on free boards) and MCP, closed at every entry point, plus click tracking.
4. **Workspaces under Organizations (revises G442).** Organization-owned workspaces, hidden personal workspaces for free users, org-admin in place of workspace admin, moving a board into an Organization, invitations, workspace tokens, export and account deletion.
5. **SSO and Organization audit (revises Goal 6).** SSO scoped to Organizations, and an Organization-scoped audit log for org-admins.
6. **Public pages and launch communication.** Rewrite `/pricing`, `/terms` and `/privacy`, and publish the announcement before launch.
