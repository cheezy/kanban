# Organizations and Workspaces

An Organization is how a team uses Stride on the paid plan. It groups the
team's people, holds the team's boards in shared workspaces, and gives the
Organization's org-admins one place to manage who is in and what they can
reach. This guide is for board owners deciding whether to move to an
Organization, and for the org-admins who run one.

It covers what an Organization and a workspace are, the two plans, how an
Organization is created, the roles, inviting people, moving a board into a
workspace, workspace tokens and export, the audit log, and what happens when
someone deletes their account. Single sign-on, SCIM provisioning and the
Organization's security policies have their own guides, linked from
[Single sign-on, SCIM and security policies](#single-sign-on-scim-and-security-policies).

> **Plan limits apply only when plans are enforced.** A Stride instance
> enforces plans only when its operator sets the environment variable
> `STRIDE_PLANS_ENFORCED` to exactly `true` and restarts it. A self-hosted
> instance does not enforce them unless you set it, so every board has every
> feature and no member limit. Workspaces, single sign-on and the
> Organization audit log are the exceptions: each belongs to an Organization,
> so it needs one in either mode. Everything in this guide that is about a
> locked feature, the three-person limit, a **Paused** webhook or the
> "Available to organizations" prompt applies only while plans are enforced.
> Organizations, workspaces, roles, invitations, board moves, the audit log
> and account deletion work the same in both modes. Operators turning
> enforcement on should follow the
> [Organizations Launch Runbook](organizations-launch-runbook.md).

## Organizations and workspaces

An **Organization** is a team on the paid plan. It has a name, an address and
a contact person, and two kinds of people: **org-admins**, who run it, and
**members**. A person belongs to at most one Organization.

A **workspace** holds boards. There are two kinds:

- **Your personal workspace.** Every account has one, and the boards you
  create outside an Organization live there. It never appears in the
  workspace switcher or in workspace settings.
- **An Organization workspace.** An Organization can have several, for
  example one per team or product. Org-admins create, rename and archive them,
  and decide who is in each one.

Whether a board is on the paid plan depends only on where it lives: a board
is paid when its workspace belongs to an Organization. Who is looking at it
does not matter, so a board in an Organization member's personal workspace is
still a free board.

People who belong to an Organization get a **workspace switcher** in the side
navigation. It lists the Organization's unarchived workspaces they can reach,
and a **Workspace settings** link for the workspace they have chosen. A new
Organization starts with no workspaces; an org-admin creates the first one.

## Plans

The pricing page names two plans:

- **Free**, "For individuals and small teams. No card required." It includes
  unlimited boards, tasks and goals, up to 3 people per board (AI agents do
  not count), any agent, the full REST API and client-side hooks, and metrics
  and exports.
- **Organization**, "For teams that need more. Contact us for pricing." It is
  everything in Free with no user or board limits, plus notifications, the
  Organization audit log, single sign-on (SSO), workspaces, bulk actions,
  integrations (webhooks), task telemetry fields and MCP access.

There is no self-serve billing. The Organization plan is set up with Stride
directly under a separate written agreement: use **Talk to us** on the
pricing page. The pricing page and the terms of service are the authority on
what each plan includes and costs; this guide describes how the product
behaves.

### What a free board cannot do

When plans are enforced, these features are locked on a free board, or for a
person who does not belong to an Organization. Where a locked feature would
appear, Stride shows its name with "Available to organizations", and
selecting it leads to the pricing page.

| Feature | Locked for | What happens |
|---|---|---|
| Notifications | Free boards, and people outside an Organization | No notifications are created for events on a free board, and nobody without paid access is emailed. Notification preferences cannot be changed without paid access. Unsubscribing always works. |
| SSO | People outside an Organization | The single sign-on settings show the lock. |
| Workspaces | People outside an Organization | The side navigation shows a locked workspace slot instead of the switcher, and workspace settings are refused. |
| Bulk actions | Free boards | Selecting several tasks to act on them at once is refused. |
| Integrations | Free boards | Webhook, Slack and Discord endpoints are paused. See [Webhooks on a free board](#webhooks-on-a-free-board). |
| Telemetry | Free boards | The task fields `telemetry_event` and `metrics_to_track` are accepted but not stored. The task form shows the lock in their place, and an API response that dropped them carries a `warnings` list saying so. |
| MCP | Free boards | A request to the MCP server for a free board gets a JSON-RPC `-32001` error whose `error.data.feature` is `"mcp"`, and no tool runs. The REST API is not affected. See [Stride MCP Server](MCP.md#errors). |

The Organization audit log is also a paid feature, but there is no locked
prompt for it: it exists only for an Organization's org-admins (see
[The Organization audit log](#the-organization-audit-log)).

A board unlocks as soon as it moves into an Organization workspace. Stride
does not cache a board's plan, so nothing has to be refreshed.

### The three-person limit

When plans are enforced, a free board holds at most 3 people. Everyone with
access to the board counts, its owner included. AI agents never count: they
use API tokens, not board memberships. A board in an Organization workspace
has no member limit, and an org-admin's access to the Organization's boards
never counts either.

The limit stops additions only. A board that already had more than 3 people
when enforcement was switched on keeps them all, and removing someone is
always allowed. While the board is at the limit, adding someone is refused
with "This board is full. Free boards hold 3 people." and the board's members
screen says "Free boards hold 3 people. To add more, move this board into an
organization." An invitation to a full board shows "This board is full" when
it is opened, and asks the invitee to have the board owner make room.

### Webhooks on a free board

When plans are enforced, a free board's webhook, Slack and Discord endpoints
are paused rather than disabled or deleted:

- No events are sent, and deliveries already queued or waiting to be retried
  are dropped.
- The Integrations tab offers only **Deliveries** and **Delete** for each
  endpoint, and no new endpoint can be added.
- An enabled endpoint shows a **Paused** badge with the note "Sends again once
  this board moves into an Organization." After the move it sends again with
  the next event, exactly as it was set up.
- A disabled endpoint shows only **Disabled**, and stays disabled after the
  move until someone enables it.

[Webhooks and Slack](webhooks.md#test-pause-and-remove-an-endpoint) has the
full description, including when Stride disables an endpoint whose creator
loses access to the board.

## Creating an Organization

Organizations are not self-serve. To start one, contact Stride with
**Talk to us** on the pricing page. A Stride site admin creates the
Organization, with its name, address and contact person, and appoints its
first org-admin by email address:

- If the address has no Stride account, a new account is created and its
  owner is emailed instructions to confirm it and set a password.
- An address whose account is disabled, or that already belongs to another
  Organization, is refused.

Only a site admin can change the Organization's details, appoint another
org-admin or remove one. Org-admins see the details as read-only on the
Organization console. Stride has no way to delete an Organization or move it
back to the free plan from the product.

## Roles

There are two Organization roles and, inside each Organization workspace, two
workspace roles.

| Role | What it allows |
|---|---|
| Org-admin | Opens the Organization console at `/org`, from the **Organization** link in the side navigation. Creates, renames and archives workspaces. Removes members from the Organization. Invites people, creates workspace tokens and exports workspaces from workspace settings. Moves their own boards into a workspace. Opens the security policy, single sign-on, SCIM and audit log pages. Has owner-level access to every board in the Organization's workspaces. |
| Member | Has paid access: the workspace switcher, notifications and single sign-on. Reaches a board only when they are a member of that board. Sees workspace settings for their workspace as a read-only list. |

The org-admin's access to boards is worked out on every request from their
role, not stored as a board membership. It ends the moment they stop being an
org-admin. An org-admin of one Organization has no access to another
Organization's boards, and being a site admin gives no access to an
Organization's console.

Org-admins cannot appoint or remove org-admins; that stays with Stride's site
admins. On the console's **Members** section an org-admin can remove only
ordinary members. Removing a member, after the confirmation "Remove this
member from the Organization? They lose their board memberships and API
tokens in every workspace of the Organization.", also unassigns their open
tasks there and removes them from every workspace, archived ones included.
Rejoining later does not bring the old access back. Boards shared with them
outside the Organization are not touched.

Inside a workspace, people are a **Member** or a **Guest**:

- A **Member** can create boards in the workspace.
- A **Guest** cannot. A guest's new boards go to their personal workspace.

An org-admin changes someone's workspace role, or removes them from the
workspace, from the **Members** section of workspace settings. Removing
someone from a workspace removes their board memberships there and revokes
their API tokens there.

Boards in an Organization workspace accept only members of that
Organization. To work with someone from outside, invite them to the
workspace (see [Inviting people](#inviting-people)).

## Managing workspaces

Org-admins manage workspaces from the **Workspaces** section of the
Organization console (`/org`):

- **Create workspace** adds one. Names are up to 100 characters and must be
  unique within the Organization, ignoring case.
- **Rename** changes the name.
- **Archive** retires a workspace. It is refused while the workspace still
  has boards. Archiving revokes the workspace's API tokens and open
  invitations and frees its name. An archived workspace cannot be restored.

Workspace settings (`/workspace/settings`) apply to the workspace chosen in
the switcher. Everyone in the workspace sees the **Members** and **Boards**
sections. Org-admins also see **Invitations**, **Tokens** and **Export**.

## Inviting people

Org-admins invite people from the **Invitations** section of workspace
settings:

1. Enter the person's **Email** and choose a **Role**, Member or Guest.
2. Optionally choose a **Board** in the workspace and the **Board access**
   they get on it, Read only or Can edit.
3. Select **Send invitation**.

The invitee gets an email with a link. The link works once and expires in 7
days. Someone without a Stride account can create one from the link with the
invited address, and the invitation is accepted once they confirm it.
**Pending invitations** lists open invitations; **Resend** sends a new link
and the old one stops working, and **Revoke** stops the link working.
Inviting the same address to the same workspace and board again renews the
existing invitation instead of adding a second one. Each person can send at
most 20 invitation emails an hour.

Accepting an invitation:

- needs the invitee to be signed in with the invited address, on a confirmed
  and enabled account;
- makes the invitee a member of the Organization, even when they were invited
  as a guest, adds them to the workspace and, if the invitation named one,
  gives them access to the board;
- never lowers an existing role, and never makes anyone an org-admin or a
  board owner.

An invitation cannot be accepted by someone who already belongs to another
Organization, or after the org-admin who sent it has lost that role. Apart
from a full free board (see
[The three-person limit](#the-three-person-limit)), every link that cannot be
used shows the same message, "This invitation link is
invalid or has expired.", so the page reveals nothing about who was invited.

On a free board, only the board's owner can invite, from the board's members
screen. That invitation gives access to that one board and nothing else, and
it counts toward the three-person limit when plans are enforced. A pending
invitation does not hold a place: if the board fills up before the invitee
accepts, the acceptance is refused until the owner makes room. On a board
in an Organization workspace only an org-admin can invite from the members
screen, and the invitation becomes a workspace invitation as a guest with
access to that board.

People can also join an Organization through single sign-on or SCIM; see
[Single sign-on, SCIM and security policies](#single-sign-on-scim-and-security-policies).

## Moving a board into a workspace

A board becomes a paid board by moving into an Organization workspace. An
org-admin moves it from the **Boards** section of workspace settings: under
**Move a board here**, choose the **Board** and select **Move here**.

The move has these rules:

- **Only the board's owner can move it, and they must be an org-admin of the
  Organization.** It must be a board they own in their personal workspace.
  An org-admin's access to the Organization's boards does not count as
  owning one. If a teammate owns the board, they transfer its ownership to an
  org-admin first.
- **Everyone on the board must already belong to the Organization.** If
  anyone does not, the move is refused and names them: "That board can't be
  moved here: … aren't members of this Organization. Remove them from the
  board, or invite them to this workspace, then move it." The move never adds
  anyone to the Organization.
- **Members keep their access.** Every board membership stays as it was.
- **Open invitations to the board are revoked.** An invitation sent from a
  free board gives board access without joining the Organization, so the move
  revokes it. Invite those people to the workspace instead.
- **Webhooks added by outsiders are disabled.** Each enabled endpoint added by
  someone who is not a member of the Organization, or whose account is gone,
  is switched off so the board's events stop going to an address an outsider
  chose. The board's owner or an org-admin can enable it again, which makes
  them its creator. Other enabled endpoints, including ones that were
  **Paused**, send again with the next event. The exception is an endpoint
  whose creator's account is disabled: it stays enabled but sends nothing,
  before and after the move, until someone disables and enables it to take it
  over. See [Webhooks and Slack](webhooks.md#when-the-person-who-added-an-endpoint-leaves).
- **There is no way back.** A board cannot be moved back to a personal
  workspace, or from one Organization workspace to another.

After the move the three-person limit no longer applies and the paid
features unlock on the board.

## Workspace tokens

A workspace token is one API token for every board in an Organization
workspace, instead of one token per board. Org-admins create and revoke them
in the **Tokens** section of workspace settings. A workspace token acts as the
org-admin who created it, reaches the AI Optimized boards in the workspace
that they can modify, and names its board on each request. It expires after
90 days, and stops working when it is revoked or when its org-admin leaves
the workspace or the Organization. The token is shown once, when it is
created.

The [Authentication Guide](AUTHENTICATION.md#board-tokens-and-workspace-tokens)
explains which kind of token to use, and how to
[create a workspace token](AUTHENTICATION.md#creating-a-workspace-token) and
name the board on each request.

## Exporting a workspace

An org-admin can download an Organization workspace as a zip archive from the
**Export** section of workspace settings, as a backup or to move the
workspace to a self-hosted Stride. Members and guests cannot export, and a
personal workspace has no export. [Workspace Export](workspace-export.md)
describes what the archive holds, how long it is kept and how to import it.

## The Organization audit log

Org-admins see their Organization's security events at `/org/audit`, with
**Audit log** on the Organization console. Only an enabled org-admin of that
Organization can open it. Anyone else is sent to their boards with "You must
be an org-admin of an Organization to access this page." That refused visit is
recorded in Stride's own site audit log, not in the Organization's.

The log shows the Organization's events newest first, 50 to a page, with times
in UTC. It can be filtered by action and by date. The events include:

- the Organization's creation and changes to it, and org-admins appointed or
  removed;
- members added and removed;
- workspaces created, renamed and archived;
- security policy changes and exports of the audit log itself;
- single sign-on, SCIM and domain events;
- API requests refused because a token on the Organization's boards or
  workspaces asked for a board it may not use, or lost access to its board.

When the person who acted was a member of the Organization at the time, the
event shows their email address and IP address. When they were not, for
example a Stride site admin creating the Organization or appointing an
org-admin, the event does not show their email address, IP address or user
id.

**Export CSV** and **Export JSON** download the events that match the current
filters, newest first, up to 50,000 events per download by default. Each
org-admin can export 10 times an hour.

Events are kept forever unless the Organization sets an audit retention
period; see [Audit retention](organization-security-policies.md#audit-retention).
No one can edit an audit event.

## Single sign-on, SCIM and security policies

These have their own guides:

- [Single Sign-On](single-sign-on.md): let members sign in through your
  identity provider, with OpenID Connect or SAML 2.0, after verifying your
  email domains.
- [SCIM Provisioning](scim-provisioning.md): create, update and deprovision
  members from your identity provider.
- [Organization Security Policies](organization-security-policies.md):
  require two-factor authentication for members, and set how long audit events
  are kept.

## When someone deletes their account

Anyone with a password can delete their own account from the **Delete
account** section of their account settings, by entering their password and
typing `delete my account`. An account created by single sign-on starts
without a password; its owner can set one with the **Forgot?** link on the
log-in page and then delete the account the same way (see
[Known limits](single-sign-on.md#known-limits)).
For someone in an Organization, Stride first checks two things:

- **The last org-admin.** If they are the last enabled org-admin of an
  Organization that has other members, the deletion is refused: "A Stride
  admin must appoint another org-admin before you can delete your account."
- **The only member.** If they are the Organization's only member, the
  deletion is allowed with a warning that nobody will be able to manage the
  Organization or open its workspaces and boards until a Stride admin
  appoints a new org-admin.

Deletion is also refused while they own a board other people use, until they
transfer its ownership or remove the others.

When they confirm, Stride deletes the account and with it their API tokens
(board and workspace tokens), their board memberships, their Organization
membership and their workspace memberships, and signs them out everywhere.
The Organization's data stays with the Organization:

- Boards in an Organization workspace stay where they are.
- The tasks and comments they added are kept without their name.
- Their claimed tasks go back to Ready, the invitations they sent are
  revoked, and the webhook endpoints they added on boards that outlive them
  are disabled.
- Security audit events that record what they did, including their email
  address and IP address, are not removed. The Organization's org-admins can
  still see the events that belong to it, for as long as its audit retention
  setting keeps them.

Someone whose account was disabled, for example by the Organization's SCIM
deprovisioning (see [Deprovisioning](scim-provisioning.md#deprovisioning)),
cannot sign in to delete it; the privacy policy says how to ask Stride to
delete it. The privacy policy and terms of service are the authority on how
long Stride keeps data.

## Where it lives

| Page | Who sees it |
|---|---|
| `/org`, the Organization console: Details, Members, Workspaces | Org-admins |
| `/org/security`, `/org/sso`, `/org/scim`, `/org/audit` | Org-admins |
| `/workspace/settings`: Members, Boards | Everyone in the workspace |
| `/workspace/settings`: Invitations, Tokens, Export | Org-admins |
| `/admin/organizations` | Stride site admins |
| Delete account in account settings | Everyone with a password |

The plan check lives in `Kanban.Plans` (`lib/kanban/plans.ex`), board moves
in `Kanban.Workspaces.BoardMoves`, and effective board access in
`Kanban.Workspaces.Policy`.
